#include "Newt/Session.h"
#include "CoreInternal.h"
#include "include/NewtLog.h"
#include <algorithm>
#include <cstring>
#include <thread>
using namespace NewtInternal;
using Newt::Session;
void Session::DrawColor(VkCommandBuffer cmd, const Mat4& viewProj, const Mat4& model,
                         const Buffer& buffer, uint32_t count, const Vec4& color, bool lines) {
    vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS,
                      lines ? mLinePipeline : mColorPipeline);
    const VkDeviceSize offset = 0;
    vkCmdBindVertexBuffers(cmd, 0, 1, &buffer.buffer, &offset);
    const ColorPush push{ Multiply(viewProj, model), color };
    vkCmdPushConstants(cmd, mColorLayout, VK_SHADER_STAGE_VERTEX_BIT, 0, sizeof(push), &push);
    vkCmdDraw(cmd, count, 1, 0, 0);
}

void Session::DrawTextured(VkCommandBuffer cmd, const Mat4& viewProj, const Mat4& model,
                            const Texture& tex, const Buffer* mesh, uint32_t vertexCount) {
    vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, mTexturePipeline);
    const VkDeviceSize offset = 0;
    vkCmdBindVertexBuffers(cmd, 0, 1, mesh ? &mesh->buffer : &mQuadBuffer.buffer, &offset);
    vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, mTexturePipelineLayout, 0, 1,
                            &tex.descriptor, 0, nullptr);
    const TexturePush push{ Multiply(viewProj, model) };
    vkCmdPushConstants(cmd, mTexturePipelineLayout, VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT, 0, sizeof(push),
                       &push);
    vkCmdDraw(cmd, vertexCount, 1, 0, 0);
}

bool Session::RenderFrame(const XrFrameState& frameState) {
    XrFrameBeginInfo beginInfo{ XR_TYPE_FRAME_BEGIN_INFO };
    CheckXr(xrBeginFrame(mSession, &beginInfo), "xrBeginFrame");

    std::vector<XrCompositionLayerBaseHeader*> layers;
    XrCompositionLayerProjection projLayer{ XR_TYPE_COMPOSITION_LAYER_PROJECTION };
    std::vector<XrCompositionLayerProjectionView> projViews;
    bool rendered = false;

    if (frameState.shouldRender) {
        XrViewLocateInfo viewLocate{ XR_TYPE_VIEW_LOCATE_INFO };
        viewLocate.viewConfigurationType = mViewType;
        viewLocate.displayTime = frameState.predictedDisplayTime;
        viewLocate.space = mAppSpace;
        XrViewState viewState{ XR_TYPE_VIEW_STATE };
        uint32_t viewCount = static_cast<uint32_t>(mViewConfigs.size());
        std::vector<XrView> views(viewCount, { XR_TYPE_VIEW });
        CheckXr(xrLocateViews(mSession, &viewLocate, &viewState, viewCount, &viewCount,
                              views.data()),
                "xrLocateViews");

        projViews.resize(viewCount);
        for (uint32_t i = 0; i < viewCount; ++i) {
            SwapchainView& sv = mSwapchains[i];
            const size_t slot = i % mCommandBuffers.size();
            VkCommandBuffer cmd = mCommandBuffers[slot];
            VkFence fence = mFences[slot];

            uint32_t imageIndex = 0;
            XrSwapchainImageAcquireInfo acquire{ XR_TYPE_SWAPCHAIN_IMAGE_ACQUIRE_INFO };
            CheckXr(xrAcquireSwapchainImage(sv.swapchain, &acquire, &imageIndex),
                    "xrAcquireSwapchainImage");
            XrSwapchainImageWaitInfo wait{ XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO };
            wait.timeout = XR_INFINITE_DURATION;
            CheckXr(xrWaitSwapchainImage(sv.swapchain, &wait), "xrWaitSwapchainImage");

            CheckVk(vkWaitForFences(mDevice, 1, &fence, VK_TRUE, UINT64_MAX), "frame fence");
            mSampledGPUTextures[slot].clear();
            mDrawingSlot = slot;
            vkResetFences(mDevice, 1, &fence);
            vkResetCommandBuffer(cmd, 0);
            VkCommandBufferBeginInfo cbbi{ VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
            cbbi.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
            CheckVk(vkBeginCommandBuffer(cmd, &cbbi), "vkBeginCommandBuffer");

            PrepareGPUTextures(cmd);
            VkClearValue clears[2]{};
            clears[0].color.float32[0] = 0.015f;
            clears[0].color.float32[1] = 0.020f;
            clears[0].color.float32[2] = 0.028f;
            clears[0].color.float32[3] = 1.0f;
            clears[1].depthStencil.depth = 1.0f;
            clears[1].depthStencil.stencil = 0;
            VkRenderPassBeginInfo rpbi{ VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO };
            rpbi.renderPass = mRenderPass;
            rpbi.framebuffer = sv.framebuffers[imageIndex];
            rpbi.renderArea.offset = { 0, 0 };
            rpbi.renderArea.extent = { sv.width, sv.height };
            rpbi.clearValueCount = 2;
            rpbi.pClearValues = clears;
            vkCmdBeginRenderPass(cmd, &rpbi, VK_SUBPASS_CONTENTS_INLINE);

            VkViewport vp{};
            vp.width = static_cast<float>(sv.width);
            vp.height = static_cast<float>(sv.height);
            vp.minDepth = 0.0f;
            vp.maxDepth = 1.0f;
            vkCmdSetViewport(cmd, 0, 1, &vp);
            VkRect2D sc{};
            sc.extent = { sv.width, sv.height };
            vkCmdSetScissor(cmd, 0, 1, &sc);

            const Mat4 viewProj = Multiply(Projection(views[i].fov, 0.05f, 100.0f),
                                           RigidInverse(PoseMatrix(views[i].pose)));

            mDelegate->OnDrawEye({cmd, viewProj, views[i], i, sv.width, sv.height});
            vkCmdEndRenderPass(cmd);
            CheckVk(vkEndCommandBuffer(cmd), "vkEndCommandBuffer");

            VkSubmitInfo si{ VK_STRUCTURE_TYPE_SUBMIT_INFO };
            si.commandBufferCount = 1;
            si.pCommandBuffers = &cmd;
            CheckVk(vkQueueSubmit(mQueue, 1, &si, fence), "vkQueueSubmit");

            XrSwapchainImageReleaseInfo release{ XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO };
            CheckXr(xrReleaseSwapchainImage(sv.swapchain, &release), "xrReleaseSwapchainImage");

            XrCompositionLayerProjectionView& pv = projViews[i];
            pv.type = XR_TYPE_COMPOSITION_LAYER_PROJECTION_VIEW;
            pv.pose = views[i].pose;
            pv.fov = views[i].fov;
            pv.subImage.swapchain = sv.swapchain;
            pv.subImage.imageRect.offset = { 0, 0 };
            pv.subImage.imageRect.extent = { static_cast<int32_t>(sv.width),
                                             static_cast<int32_t>(sv.height) };
            pv.subImage.imageArrayIndex = 0;
        }

        mPendingGPUTextures.clear();

        projLayer.space = mAppSpace;
        projLayer.viewCount = viewCount;
        projLayer.views = projViews.data();
        layers.push_back(reinterpret_cast<XrCompositionLayerBaseHeader*>(&projLayer));
        rendered = true;
    }

    XrFrameEndInfo endInfo{ XR_TYPE_FRAME_END_INFO };
    endInfo.displayTime = frameState.predictedDisplayTime;
    endInfo.environmentBlendMode = XR_ENVIRONMENT_BLEND_MODE_OPAQUE;
    endInfo.layerCount = static_cast<uint32_t>(layers.size());
    endInfo.layers = layers.data();
    CheckXr(xrEndFrame(mSession, &endInfo), "xrEndFrame");
    return rendered;
}
