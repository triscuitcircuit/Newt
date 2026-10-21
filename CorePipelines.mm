#include "Newt/Session.h"
#include "CoreInternal.h"
#include "include/NewtLog.h"
#include <algorithm>
#include <cstring>
#include <thread>
using namespace NewtInternal;
using Newt::Session;
#include "color_vert.h"
#include "color_frag.h"
#include "texture_vert.h"
#include "texture_frag.h"
void Session::CreateRenderAssets() {
    VkSamplerCreateInfo sci{ VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO };
    sci.magFilter = VK_FILTER_LINEAR;
    sci.minFilter = VK_FILTER_LINEAR;
    sci.mipmapMode = VK_SAMPLER_MIPMAP_MODE_LINEAR;
    sci.addressModeU = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
    sci.addressModeV = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
    sci.addressModeW = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
    sci.minLod = 0.0f;
    sci.maxLod = 0.0f;
    sci.maxAnisotropy = 1.0f;
    CheckVk(vkCreateSampler(mDevice, &sci, nullptr, &mSampler), "vkCreateSampler");

    VkDescriptorSetLayoutBinding binding{};
    binding.binding = 0;
    binding.descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    binding.descriptorCount = 1;
    binding.stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT;
    VkDescriptorSetLayoutCreateInfo dlci{ VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO };
    dlci.bindingCount = 1;
    dlci.pBindings = &binding;
    CheckVk(vkCreateDescriptorSetLayout(mDevice, &dlci, nullptr, &mTextureLayout),
            "vkCreateDescriptorSetLayout");

    VkDescriptorPoolSize poolSize{};
    poolSize.type = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    poolSize.descriptorCount = 128;
    VkDescriptorPoolCreateInfo dpci{ VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO };
    dpci.maxSets = 128;
    dpci.flags = VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT;
    dpci.poolSizeCount = 1;
    dpci.pPoolSizes = &poolSize;
    CheckVk(vkCreateDescriptorPool(mDevice, &dpci, nullptr, &mDescriptorPool),
            "vkCreateDescriptorPool");

    VkCommandPoolCreateInfo cpci{ VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO };
    cpci.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    cpci.queueFamilyIndex = mQueueFamily;
    CheckVk(vkCreateCommandPool(mDevice, &cpci, nullptr, &mCommandPool), "vkCreateCommandPool");
    VkCommandBufferAllocateInfo cbai{ VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO };
    cbai.commandPool = mCommandPool;
    cbai.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    cbai.commandBufferCount = static_cast<uint32_t>(mCommandBuffers.size());
    CheckVk(vkAllocateCommandBuffers(mDevice, &cbai, mCommandBuffers.data()),
            "vkAllocateCommandBuffers");
    VkFenceCreateInfo fci{ VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
    fci.flags = VK_FENCE_CREATE_SIGNALED_BIT;
    for (VkFence& fence : mFences) {
        CheckVk(vkCreateFence(mDevice, &fci, nullptr, &fence), "vkCreateFence");
    }

    const std::vector<VertexPC> quad = MakeQuad();
    mQuadBuffer = CreateBuffer(quad.size() * sizeof(VertexPC), VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
    UploadBuffer(mQuadBuffer, quad.data(), quad.size() * sizeof(VertexPC));

}

void Session::CreatePipelines() {
    VkShaderModule colorVert = CreateShader(color_vert_spv, color_vert_spv_len);
    VkShaderModule colorFrag = CreateShader(color_frag_spv, color_frag_spv_len);
    VkShaderModule texVert = CreateShader(texture_vert_spv, texture_vert_spv_len);
    VkShaderModule texFrag = CreateShader(texture_frag_spv, texture_frag_spv_len);

    VkPushConstantRange colorPush{};
    colorPush.stageFlags = VK_SHADER_STAGE_VERTEX_BIT;
    colorPush.offset = 0;
    colorPush.size = sizeof(ColorPush);
    VkPipelineLayoutCreateInfo colorPlci{ VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO };
    colorPlci.pushConstantRangeCount = 1;
    colorPlci.pPushConstantRanges = &colorPush;
    CheckVk(vkCreatePipelineLayout(mDevice, &colorPlci, nullptr, &mColorLayout),
            "vkCreatePipelineLayout(color)");

    VkPushConstantRange texPush{};
    texPush.stageFlags = VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT;
    texPush.offset = 0;
    texPush.size = sizeof(TexturePush);
    VkPipelineLayoutCreateInfo texPlci{ VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO };
    texPlci.setLayoutCount = 1;
    texPlci.pSetLayouts = &mTextureLayout;
    texPlci.pushConstantRangeCount = 1;
    texPlci.pPushConstantRanges = &texPush;
    CheckVk(vkCreatePipelineLayout(mDevice, &texPlci, nullptr, &mTexturePipelineLayout),
            "vkCreatePipelineLayout(texture)");

    VkVertexInputBindingDescription colorBind{};
    colorBind.binding = 0;
    colorBind.stride = sizeof(Vec3);
    colorBind.inputRate = VK_VERTEX_INPUT_RATE_VERTEX;
    VkVertexInputAttributeDescription colorAttr{};
    colorAttr.location = 0;
    colorAttr.binding = 0;
    colorAttr.format = VK_FORMAT_R32G32B32_SFLOAT;
    colorAttr.offset = 0;

    VkVertexInputBindingDescription texBind{};
    texBind.binding = 0;
    texBind.stride = sizeof(VertexPC);
    texBind.inputRate = VK_VERTEX_INPUT_RATE_VERTEX;
    VkVertexInputAttributeDescription texAttrs[2]{};
    texAttrs[0].location = 0;
    texAttrs[0].binding = 0;
    texAttrs[0].format = VK_FORMAT_R32G32B32_SFLOAT;
    texAttrs[0].offset = offsetof(VertexPC, pos);
    texAttrs[1].location = 1;
    texAttrs[1].binding = 0;
    texAttrs[1].format = VK_FORMAT_R32G32_SFLOAT;
    texAttrs[1].offset = offsetof(VertexPC, uv);

    VkPipelineVertexInputStateCreateInfo colorVi{ VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO };
    colorVi.vertexBindingDescriptionCount = 1;
    colorVi.pVertexBindingDescriptions = &colorBind;
    colorVi.vertexAttributeDescriptionCount = 1;
    colorVi.pVertexAttributeDescriptions = &colorAttr;
    VkPipelineVertexInputStateCreateInfo texVi{ VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO };
    texVi.vertexBindingDescriptionCount = 1;
    texVi.pVertexBindingDescriptions = &texBind;
    texVi.vertexAttributeDescriptionCount = 2;
    texVi.pVertexAttributeDescriptions = texAttrs;

    VkPipelineInputAssemblyStateCreateInfo triIa{ VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO };
    triIa.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
    VkPipelineInputAssemblyStateCreateInfo lineIa{ VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO };
    lineIa.topology = VK_PRIMITIVE_TOPOLOGY_LINE_LIST;

    VkViewport viewport{ 0.0f, 0.0f, 1.0f, 1.0f, 0.0f, 1.0f };
    VkRect2D scissor{ { 0, 0 }, { 1, 1 } };
    VkPipelineViewportStateCreateInfo vpState{ VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO };
    vpState.viewportCount = 1;
    vpState.pViewports = &viewport;
    vpState.scissorCount = 1;
    vpState.pScissors = &scissor;

    VkPipelineRasterizationStateCreateInfo raster{ VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO };
    raster.polygonMode = VK_POLYGON_MODE_FILL;
    raster.cullMode = VK_CULL_MODE_NONE;
    raster.frontFace = VK_FRONT_FACE_COUNTER_CLOCKWISE;
    raster.lineWidth = 1.0f;

    VkPipelineMultisampleStateCreateInfo msaa{ VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO };
    msaa.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT;

    VkPipelineDepthStencilStateCreateInfo depth{ VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO };
    depth.depthTestEnable = VK_TRUE;
    depth.depthWriteEnable = VK_TRUE;
    depth.depthCompareOp = VK_COMPARE_OP_LESS;

    VkPipelineColorBlendAttachmentState blendAtt{};
    blendAtt.blendEnable = VK_TRUE;
    blendAtt.srcColorBlendFactor = VK_BLEND_FACTOR_SRC_ALPHA;
    blendAtt.dstColorBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
    blendAtt.colorBlendOp = VK_BLEND_OP_ADD;
    blendAtt.srcAlphaBlendFactor = VK_BLEND_FACTOR_ONE;
    blendAtt.dstAlphaBlendFactor = VK_BLEND_FACTOR_ZERO;
    blendAtt.alphaBlendOp = VK_BLEND_OP_ADD;
    blendAtt.colorWriteMask = VK_COLOR_COMPONENT_R_BIT | VK_COLOR_COMPONENT_G_BIT |
                              VK_COLOR_COMPONENT_B_BIT | VK_COLOR_COMPONENT_A_BIT;
    VkPipelineColorBlendStateCreateInfo blend{ VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO };
    blend.attachmentCount = 1;
    blend.pAttachments = &blendAtt;

    const VkDynamicState dynStates[] = { VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR };
    VkPipelineDynamicStateCreateInfo dyn{ VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO };
    dyn.dynamicStateCount = 2;
    dyn.pDynamicStates = dynStates;

    auto makeShaderStages = [](VkShaderModule vert, VkShaderModule frag) {
        VkPipelineShaderStageCreateInfo stages[2]{};
        stages[0].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
        stages[0].stage = VK_SHADER_STAGE_VERTEX_BIT;
        stages[0].module = vert;
        stages[0].pName = "main";
        stages[1].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
        stages[1].stage = VK_SHADER_STAGE_FRAGMENT_BIT;
        stages[1].module = frag;
        stages[1].pName = "main";
        return std::array<VkPipelineShaderStageCreateInfo, 2>{ stages[0], stages[1] };
    };
    const auto colorStages = makeShaderStages(colorVert, colorFrag);
    const auto texStages = makeShaderStages(texVert, texFrag);

    VkGraphicsPipelineCreateInfo pci{ VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO };
    pci.pViewportState = &vpState;
    pci.pRasterizationState = &raster;
    pci.pMultisampleState = &msaa;
    pci.pDepthStencilState = &depth;
    pci.pColorBlendState = &blend;
    pci.pDynamicState = &dyn;
    pci.renderPass = mRenderPass;
    pci.subpass = 0;

    pci.stageCount = 2;
    pci.pStages = colorStages.data();
    pci.pVertexInputState = &colorVi;
    pci.pInputAssemblyState = &triIa;
    pci.layout = mColorLayout;
    CheckVk(vkCreateGraphicsPipelines(mDevice, VK_NULL_HANDLE, 1, &pci, nullptr, &mColorPipeline),
            "vkCreateGraphicsPipelines(color)");

    pci.pInputAssemblyState = &lineIa;
    CheckVk(vkCreateGraphicsPipelines(mDevice, VK_NULL_HANDLE, 1, &pci, nullptr, &mLinePipeline),
            "vkCreateGraphicsPipelines(line)");

    pci.pStages = texStages.data();
    pci.pVertexInputState = &texVi;
    pci.pInputAssemblyState = &triIa;
    pci.layout = mTexturePipelineLayout;
    CheckVk(vkCreateGraphicsPipelines(mDevice, VK_NULL_HANDLE, 1, &pci, nullptr, &mTexturePipeline),
            "vkCreateGraphicsPipelines(texture)");

    vkDestroyShaderModule(mDevice, colorVert, nullptr);
    vkDestroyShaderModule(mDevice, colorFrag, nullptr);
    vkDestroyShaderModule(mDevice, texVert, nullptr);
    vkDestroyShaderModule(mDevice, texFrag, nullptr);
}
