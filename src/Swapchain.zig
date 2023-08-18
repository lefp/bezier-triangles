const vk_procs = @import("vulkan_procedures.zig");
const util = @import("util.zig");

const vk = @import("vulkan");

const std = @import("std");
const debug = std.debug;
const log = std.log.scoped(.Swapchain);

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const Swapchain = @This();

//
// ===========================================================================================================
//

swapchain: vk.SwapchainKHR,
extent: vk.Extent2D,
/// Tracks `VK_SUBOPTIMAL_KHR`; doesn't track "VK_ERROR_OUT_OF_DATE_KHR".
is_suboptimal: bool,
// @todo I imagine the number of images in the swapchain in practice will remain constant during runtime. So
// we could just allocate an array during `init()` instead of using an ArrayList.
// @todo I imagine we aren't likely to have more than 3 images. We should probably use small stack-allocated
// arrays and only heap-allocate as a backup if for some reason we have more.

// This stuff remains constant over the lifetime of the Swapchain object
device: vk.Device,
physical_device: vk.PhysicalDevice,
window_surface: vk.SurfaceKHR,
queue_family_index_that_will_use_swapchain_images: u32,

//
// ===========================================================================================================
//

// @todo Haven't thought about what format I actually want. Come back and think about it.
pub const surface_format = vk.SurfaceFormatKHR {
    .format = .b8g8r8a8_srgb,
    .color_space = .srgb_nonlinear_khr,
};

pub fn init(
    device: vk.Device,
    physical_device: vk.PhysicalDevice,
    window_surface: vk.SurfaceKHR,
    window_size: vk.Extent2D,
    queue_family_index: u32,
    allocator: Allocator,
) !Swapchain {

    verify_format_supported: {
        // Vk 1.3, VUID-VkSwapchainCreateInfoKHR-imageFormat-01273:
        //     `imageFormat` and `imageColorSpace` must match the `format` and `colorSpace`
        //     members, respectively, of one of the `VkSurfaceFormatKHR` structures returned by
        //     `vkGetPhysicalDeviceSurfaceFormatsKHR` for the surface

        var format_count: u32 = undefined;
        {
            const result = try vk_procs.instance.getPhysicalDeviceSurfaceFormatsKHR(
                physical_device,
                window_surface,
                &format_count,
                null,
            );
            debug.assert(result == .success); // otherwise `.incomplete`, which should be impossible
        }
        //
        const formats = try allocator.alloc(vk.SurfaceFormatKHR, format_count);
        defer allocator.free(formats);
        {
            const result = try vk_procs.instance.getPhysicalDeviceSurfaceFormatsKHR(
                physical_device,
                window_surface,
                &format_count,
                formats.ptr,
            );
            debug.assert(result == .success); // otherwise `.incomplete`, which should be impossible
        }

        for (formats) |format| {
            if (
                format.format      == surface_format.format and
                format.color_space == surface_format.color_space
            ) break :verify_format_supported;
        }
        @panic("Window surface doesn't support expected format.");
    }

    const swapchain_and_extent = try createSwapchain(
        null,
        device,
        physical_device,
        window_surface,
        window_size,
        queue_family_index,
    );
    const swapchain = swapchain_and_extent.swapchain;
    const swapchain_extent = swapchain_and_extent.extent;

    return Swapchain {
        .swapchain = swapchain,
        .extent = swapchain_extent,
        .is_suboptimal = false,

        .device = device,
        .physical_device = physical_device,
        .window_surface = window_surface,
        .queue_family_index_that_will_use_swapchain_images = queue_family_index,
    };
}

// @note Vk spec 1.3.234:
//     Upon calling vkCreateSwapchainKHR with an oldSwapchain that is not VK_NULL_HANDLE, oldSwapchain is
//     retired — even if creation of the new swapchain fails.
pub fn rebuild(self: *Swapchain, window_size: vk.Extent2D) !void {
    self.is_suboptimal = false;

    const old_swapchain = self.swapchain;
    const result = try createSwapchain(
        old_swapchain,
        self.device,
        self.physical_device,
        self.window_surface,
        window_size,
        self.queue_family_index_that_will_use_swapchain_images,
    );
    self.swapchain = result.swapchain;
    self.extent = result.extent;

    vk_procs.device.destroySwapchainKHR(self.device, old_swapchain, null);
}

pub fn deinit(self: *Swapchain) void {
    vk_procs.device.destroySwapchainKHR(self.device, self.swapchain, null);
}

/// Returns the index of the acquired image.
pub fn acquireNextImage(
    self: *Swapchain,
    signal_semaphore: vk.Semaphore,
    signal_fence: vk.Fence,
) error{OutOfDate}!u32 {
    const result = vk_procs.device.acquireNextImageKHR(
        self.device,
        self.swapchain,
        std.math.maxInt(u64),
        signal_semaphore,
        signal_fence,
    )
    catch |err| switch (err) {
        error.OutOfDateKHR => return error.OutOfDate,
        else => debug.panic("Failed to get swapchain image; got error `{s}`", .{ @errorName(err) }),
    };

    self.is_suboptimal = switch (result.result) {
        .success => false,
        .suboptimal_khr => true,
        else => debug.panic("vkAcquireNextImageKHR returned `{s}`", .{ @tagName(result.result) }),
    };

    return result.image_index;
}

pub fn present(
    self: *Swapchain,
    queue: vk.Queue,
    image_index: u32,
    wait_semaphores: []vk.Semaphore,
) !void {

    const present_info = vk.PresentInfoKHR {
        .wait_semaphore_count = @intCast(wait_semaphores.len),
        .p_wait_semaphores = wait_semaphores.ptr,
        .swapchain_count = 1,
        .p_swapchains = util.asUnitArrayPtr(&self.swapchain),
        .p_image_indices = util.asUnitArrayPtr(&image_index),
    };

    const result = try vk_procs.device.queuePresentKHR(queue, &present_info);

    self.is_suboptimal = switch (result) {
        .success => false,
        .suboptimal_khr => true,
        // @todo this should be unreachable
        else => debug.panic("vkQueuePresentKHR returned {s}", .{ @tagName(result) }),
    };
}

/// The returned images are owned by the swapchain; you must not call `vkDestroy...` on them.
pub fn getImages(self: Swapchain, images_out: *ArrayList(vk.Image)) !void {

    var swapchain_image_count: u32 = undefined;
    {
        const result = try vk_procs.device.getSwapchainImagesKHR(
            self.device,
            self.swapchain,
            &swapchain_image_count,
            null,
        );
        debug.assert(result == .success); // otherwise `.incomplete`, which should be impossible
    }
    //
    try images_out.resize(swapchain_image_count);
    {
        const result = try vk_procs.device.getSwapchainImagesKHR(
            self.device,
            self.swapchain,
            &swapchain_image_count,
            images_out.items.ptr,
        );
        debug.assert(result == .success); // otherwise `.incomplete`, which should be impossible
    }
}

//
// ===========================================================================================================
//

const SwapchainAndExtent = struct {
    swapchain: vk.SwapchainKHR,
    extent: vk.Extent2D,
};
/// Doesn't destroy the old swapchain; that's the caller's responsibility.
/// `queue_family_index` refers to the queue family that will be used to access the swapchain images.
/// `window_size` is the current size of the window associated with the surface.
fn createSwapchain(
    old_swapchain: ?vk.SwapchainKHR,
    device: vk.Device,
    physical_device: vk.PhysicalDevice,
    window_surface: vk.SurfaceKHR,
    window_size: vk.Extent2D,
    queue_family_index: u32,
) !SwapchainAndExtent {

    const window_surface_capabilities = try vk_procs.instance.getPhysicalDeviceSurfaceCapabilitiesKHR(
        physical_device,
        window_surface,
    );

    const swapchain_extent = blk: {
        // @todo Vk spec 1.3.234:
        // "On some platforms, it is normal that maxImageExtent may become (0, 0), for example when the window
        // is minimized. In such a case, it is not possible to create a swapchain due to the Valid Usage
        // requirements."

        // "currentExtent is the current width and height of the surface, or the special value (0xFFFFFFFF,
        // 0xFFFFFFFF) indicating that the surface size will be determined by the extent of a swapchain
        // targeting the surface." - Vk spec 1.3.234, in definition of `VkSurfaceCapabilitiesKHR`
        const current_extent = window_surface_capabilities.current_extent;
        if (current_extent.width == 0xFF_FF_FF_FF) { // assuming height to have that value iff width does
            // now we get to choose the window surface's extent ourselves
            const min_allowed_extent = window_surface_capabilities.min_image_extent;
            const max_allowed_extent = window_surface_capabilities.max_image_extent;
            if (
                !isInInterval(window_size.width , min_allowed_extent.width , max_allowed_extent.width ) or
                !isInInterval(window_size.height, min_allowed_extent.height, max_allowed_extent.height)
            ) @panic("Requested window dimensions are not within the window's allowed surface dimensions");

            break :blk vk.Extent2D {
                .width  = window_size.width,
                .height = window_size.height,
            };
        }
        else break :blk current_extent;
    };

    const swapchain_info = vk.SwapchainCreateInfoKHR {
        .surface = window_surface,
        // @todo @optimize might want to set min_image_count = capabilities.min_image_count + 1; see
        // Vk spec 1.3.234, VK_KHR_swapchain, issue 12. Keep in mind it must also be less than the max
        // allowed by the driver / presentation engine.
        .min_image_count = window_surface_capabilities.min_image_count,
        .image_format = surface_format.format,
        .image_color_space = surface_format.color_space,
        .image_extent = swapchain_extent,
        .image_array_layers = 1,
        .image_usage = .{ .color_attachment_bit = true }, // i.e. it'll receive graphics pipeline output
        .image_sharing_mode = .exclusive,
        .queue_family_index_count = 1,
        .p_queue_family_indices = &[1]u32 { queue_family_index },
        .pre_transform = .{ .identity_bit_khr = true },
        .composite_alpha = .{ .opaque_bit_khr = true },
        .present_mode = .fifo_khr, // @todo maybe prefer a different mode if available
        // "specifies whether the Vulkan implementation is allowed to discard rendering operations that
        // affect regions of the surface that are not visible"; @todo allowing for now, but haven't really
        // thought about it.
        .clipped = vk.TRUE,
        .old_swapchain = old_swapchain orelse .null_handle,
    };

    const swapchain = vk_procs.device.createSwapchainKHR(device, &swapchain_info, null)
    catch @panic("Failed to create swapchain");
    errdefer vk_procs.device.destroySwapchainKHR(device, swapchain, null);

    return SwapchainAndExtent { .swapchain = swapchain, .extent = swapchain_extent };
}

/// Overwrites the `out` contents. The caller is responsible for destroying any objects they refer to
/// beforehand.
fn createFramebuffers(
    framebuffers_out: *ArrayList(vk.Framebuffer),
    image_views_out: *ArrayList(vk.ImageView),
    images_out: *ArrayList(vk.Image),
    device: vk.Device,
    swapchain: vk.Swapchain,
    swapchain_extent: vk.Extent2D,
    render_pass: vk.RenderPass,
) !void {

    var swapchain_image_count: u32 = undefined;
    {
        const result = try vk_procs.device.getSwapchainImagesKHR(
            device,
            swapchain,
            &swapchain_image_count,
            null,
        );
        debug.assert(result == .success); // otherwise `.incomplete`, which should be impossible
    }
    //
    try images_out.resize(swapchain_image_count);
    {
        const result = try vk_procs.device.getSwapchainImagesKHR(
            device,
            swapchain,
            &swapchain_image_count,
            images_out,
        );
        debug.assert(result == .success); // otherwise `.incomplete`, which should be impossible
    }

    try image_views_out.resize(swapchain_image_count);
    try framebuffers_out.resize(swapchain_image_count);
    for (0..swapchain_image_count) |image_index| {
        const image_view_info = vk.ImageViewCreateInfo {
            .image = images_out[image_index],
            .view_type = .@"2d",
            .format = surface_format.format,
            .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
            // @todo haven't thought about the .subresource_range values
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        };
        const image_view = vk_procs.device.createImageView(device, &image_view_info, null)
        catch @panic("Failed to create image view");

        const framebuffer_info = vk.FramebufferCreateInfo {
            .render_pass = render_pass,
            .attachment_count = 1,
            .p_attachments = util.asUnitArrayPtr(&image_views_out[image_index]),
            .width  = swapchain_extent.width,
            .height = swapchain_extent.height,
            .layers = 1,
        };
        const framebuffer = vk_procs.device.createFramebuffer(device, &framebuffer_info, null)
        catch @panic("Failed to create framebuffer");

        image_views_out[image_index] = image_view;
        framebuffers_out[image_index] = framebuffer;
    }
    // @todo errdefer destroy image views and framebuffers?
}

fn isInInterval(val: anytype, min: anytype, max: anytype) bool {
    return val == std.math.clamp(val, min, max);
}

