#ifndef NEWT_CORE_INTERNAL_H
#define NEWT_CORE_INTERNAL_H
#include "Newt/Session.h"
#include <deque>
#include <exception>
namespace NewtInternal {
inline void SetPrimaryViewType(XrSessionBeginInfo& bi, XrViewConfigurationType viewType) {
    bi.primaryViewConfigurationType = viewType;
}

inline void ImmediateSubmit(VkDevice device, VkQueue queue, VkCommandPool pool,
                     const std::function<void(VkCommandBuffer)>& record) {
    VkCommandBufferAllocateInfo allocInfo{ VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO };
    allocInfo.commandPool = pool;
    allocInfo.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    allocInfo.commandBufferCount = 1;
    VkCommandBuffer cmd = VK_NULL_HANDLE;
    CheckVk(vkAllocateCommandBuffers(device, &allocInfo, &cmd), "vkAllocateCommandBuffers(imm)");
    auto release = [device, pool](VkCommandBuffer_T* buffer) noexcept {
        VkCommandBuffer owned = buffer;
        vkFreeCommandBuffers(device, pool, 1, &owned);
    };
    const std::unique_ptr<VkCommandBuffer_T, decltype(release)> owned(cmd, release);
    VkCommandBufferBeginInfo beginInfo{ VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
    beginInfo.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    CheckVk(vkBeginCommandBuffer(cmd, &beginInfo), "vkBeginCommandBuffer(imm)");
    record(cmd);
    CheckVk(vkEndCommandBuffer(cmd), "vkEndCommandBuffer(imm)");
    VkSubmitInfo submitInfo{ VK_STRUCTURE_TYPE_SUBMIT_INFO };
    submitInfo.commandBufferCount = 1;
    submitInfo.pCommandBuffers = &cmd;
    CheckVk(vkQueueSubmit(queue, 1, &submitInfo, VK_NULL_HANDLE), "vkQueueSubmit(imm)");
    CheckVk(vkQueueWaitIdle(queue), "vkQueueWaitIdle(imm)");

}
} // namespace NewtInternal
#endif
