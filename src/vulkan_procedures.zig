//! When initialized, these global variables store the dynamically-loaded Vulkan procedures we will use.
//!
//! 1. The programmer lists every Vulkan procedure they intend to use in the appropriate wrapper functions.
//! 2. At comptime, each wrapper function generates a struct definition with pointers for the listed procedures.
//! 3. At runtime, we initialize an instance of each global variable; each struct's init function dynamically
//!    loads all of its listed procedures.
//!
//! This system has the following benefit:
//!   As long as we remember to initialize the three global variables, we can't accidentally use a Vulkan
//!   procedure that we forgot to load. Trying to call a Vulkan procedure that we didn't list in the wrapper
//!   wrapper functions causes an error at comptime, because the struct definitions they return only contain
//!   members for the procedures we listed.

const vk = @import("vulkan");

// Variables to store the procedures. Must be initialized at runtime.
pub var base: VulkanBaseProcs = undefined;
pub var instance: VulkanInstanceProcs = undefined;
pub var device: VulkanDeviceProcs = undefined;

pub const VulkanBaseProcs = vk.BaseWrapper(.{
    .createInstance = true,
});
pub const VulkanInstanceProcs = vk.InstanceWrapper(.{
    .createDevice = true,
    .destroyInstance = true,
    .destroySurfaceKHR = true,
    .enumeratePhysicalDevices = true,
    .getDeviceProcAddr = true,
    .getPhysicalDeviceMemoryProperties = true,
    .getPhysicalDeviceProperties = true,
    .getPhysicalDeviceQueueFamilyProperties = true,
    .getPhysicalDeviceSurfaceCapabilitiesKHR = true,
    .getPhysicalDeviceSurfaceFormatsKHR = true,
});
pub const VulkanDeviceProcs = vk.DeviceWrapper(.{
    .acquireNextImageKHR = true,
    .allocateCommandBuffers = true,
    .allocateMemory = true,
    .beginCommandBuffer = true,
    .bindBufferMemory = true,
    .cmdBeginRenderPass = true,
    .cmdBindPipeline = true,
    .cmdBindVertexBuffers = true,
    .cmdDraw = true,
    .cmdEndRenderPass = true,
    .cmdPushConstants = true,
    .cmdSetScissor = true,
    .cmdSetViewport = true,
    .createBuffer = true,
    .createCommandPool = true,
    .createFence = true,
    .createFramebuffer = true,
    .createGraphicsPipelines = true,
    .createImage = true,
    .createImageView = true,
    .createPipelineLayout = true,
    .createRenderPass = true,
    .createSemaphore = true,
    .createShaderModule = true,
    .createSwapchainKHR = true,
    .destroyFramebuffer = true,
    .destroyImage = true,
    .destroyImageView = true,
    .destroyShaderModule = true,
    .destroySwapchainKHR = true,
    .endCommandBuffer = true,
    .flushMappedMemoryRanges = true,
    .getBufferMemoryRequirements = true,
    .getDeviceQueue = true,
    .getSwapchainImagesKHR = true,
    .mapMemory = true,
    .queueSubmit = true,
    .queuePresentKHR = true,
    .resetCommandBuffer = true,
    .resetFences = true,
    .waitForFences = true,
});


