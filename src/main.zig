const util = @import("util.zig");
const Swapchain = @import("Swapchain.zig");
const shaders = @import("shaders");

const glfw = @import("mach-glfw");
const vk = @import("vulkan");

const std = @import("std");
const builtin = @import("builtin");
const debug = std.debug;
const log = std.log;

const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const asUnitArrayPtr = util.asUnitArrayPtr;

//
// GLOBAL CONSTANTS ==========================================================================================
//

const N_LINE_SEGMENTS_PER_CURVE = 100;
const LINE_THICKNESS: f32 = 10.0;

const CURVE_COUNT = 8;


const VULKAN_VERSION = vk.API_VERSION_1_3;

// This has nothing to do with window size; I'm just using the same values as the old program, which used
// window size.
const WORLD_SIZE_X: f32 = 1920;
const WORLD_SIZE_Y: f32 = 1080;

//
// GLOBAL VARIABLES ==========================================================================================
//

/// contains procedures that need to be initialized at runtime
const vk_procs_ = @import("vulkan_procedures.zig");

var window_: glfw.Window = undefined;

var device_: vk.Device = undefined;
var graphics_present_queue_family_index_: u32 = undefined;
var graphics_present_queue_: vk.Queue = undefined;

var render_pass_: vk.RenderPass = undefined;

var command_buffer_: vk.CommandBuffer = undefined;

var pipeline_: vk.Pipeline = undefined;
var pipeline_layout_: vk.PipelineLayout = undefined;

var swapchain_: Swapchain = undefined;
/// Scratch buffer for intermediate data.
var swapchain_images_scratch_: ArrayList(vk.Image) = undefined;
var swapchain_image_views_: ArrayList(vk.ImageView) = undefined;
var swapchain_framebuffers_: ArrayList(vk.Framebuffer) = undefined;

var render_area_: vk.Rect2D = undefined;

var swapchain_image_acquired_semaphore_: vk.Semaphore = undefined;
var render_finished_semaphore_: vk.Semaphore = undefined;
var command_buffer_pending_fence_: vk.Fence = undefined;


var curve_control_points_: []CurveControlPoints = undefined;
var curve_colors_: []CurveColors = undefined;

var curves_buffer_: AllocatedBuffer = undefined;
var curve_control_points_offset_in_buffer_: vk.DeviceSize = undefined;
var curve_colors_offset_in_buffer_: vk.DeviceSize = undefined;

var mapped_curve_control_points_ptr_: [*]u8 = undefined;
var mapped_curve_colors_ptr_: [*]u8 = undefined;

//
// ===========================================================================================================
//

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = arena.allocator();

    try init(allocator, 800, 450);

    // @todo @placeholder, should initialize randomly in `init()`
    for (0..CURVE_COUNT) |curve_index| {

        curve_control_points_[curve_index] = CurveControlPoints {
            .point_1_pos = .{ 100.0 + 100.0*@as(f32, @floatFromInt(curve_index)), 100.0 },
            .point_2_pos = .{ 500.0 + 100.0*@as(f32, @floatFromInt(curve_index)), 200.0 },
            .point_3_pos = .{ 100.0 + 100.0*@as(f32, @floatFromInt(curve_index)), 300.0 },
            .point_4_pos = .{ 300.0 + 100.0*@as(f32, @floatFromInt(curve_index)), 400.0 },
        };

        curve_colors_[curve_index] = CurveColors {
            .start_color = .{   0, 255, 255, 255 },
            .end_color   = .{ 255, 255,   0, 255 },
        };
    }

    glfw.pollEvents();
    while (!window_.shouldClose()) {
        try update();
        try draw();

        glfw.pollEvents();
    }
}

fn update() !void {
    // @todo @continue
}

fn draw() !void {

    const acquired_swapchain_image_index = acquireNextImage_rebuildSwapchainUntilSuccess(
        &swapchain_,
        swapchain_image_acquired_semaphore_,
        .null_handle, // `signal_fence`
    );
    const swapchain_framebuffer = swapchain_framebuffers_.items[acquired_swapchain_image_index];

    try util.waitForFenceBlocking(device_, &command_buffer_pending_fence_);
    try vk_procs_.device.resetFences(device_, 1, asUnitArrayPtr(&command_buffer_pending_fence_));


    @memcpy(mapped_curve_control_points_ptr_, std.mem.sliceAsBytes(curve_control_points_));
    @memcpy(mapped_curve_colors_ptr_, std.mem.sliceAsBytes(curve_colors_));

    const memory_ranges_to_flush = [1]vk.MappedMemoryRange {
        .{
            .memory = curves_buffer_.backing_memory,
            .offset = curves_buffer_.offset_in_memory,
            .size = curves_buffer_.size,
        },
    };
    try vk_procs_.device.flushMappedMemoryRanges(
        device_,
        memory_ranges_to_flush.len,
        &memory_ranges_to_flush,
    );


    // @todo if we always record the command buffer with the same commands each time, we should probably
    // not bother re-recording it (in which case, don't set `.one_time_submit`). Note that the spec says we
    // still have to reset the buffer after calling `endCommandBuffer` before reusing it.
    try vk_procs_.device.resetCommandBuffer(command_buffer_, .{});

    try vk_procs_.device.beginCommandBuffer(
        command_buffer_,
        &.{ .flags = .{ .one_time_submit_bit = true } },
    );

    // inside command buffer
    {
        const render_pass_begin_info = vk.RenderPassBeginInfo {
            .render_pass = render_pass_,
            .framebuffer = swapchain_framebuffer,
            .render_area = vk.Rect2D {
                .offset = .{ .x = 0, .y = 0 },
                .extent = swapchain_.extent,
            },
            .clear_value_count = 1,
            .p_clear_values = &[1]vk.ClearValue {
                .{ .color = .{ .float_32 = .{ 0, 0, 0, 1 } } },
            },
        };

        vk_procs_.device.cmdBeginRenderPass(
            command_buffer_,
            &render_pass_begin_info,
            vk.SubpassContents.@"inline",
        );

        vk_procs_.device.cmdBindPipeline(command_buffer_, .graphics, pipeline_);

        vk_procs_.device.cmdSetViewport(
            command_buffer_,
            0, // first_viewport
            1, // viewport_count
            asUnitArrayPtr(&vk.Viewport {
                .x = @floatFromInt(render_area_.offset.x),
                .y = @floatFromInt(render_area_.offset.y),
                .width = @floatFromInt(render_area_.extent.width),
                .height = @floatFromInt(render_area_.extent.height),
                .min_depth = 0.0, // @todo ??
                .max_depth = 1.0, // @todo ??
            }),
        );
        vk_procs_.device.cmdSetScissor(
            command_buffer_,
            0, // first_scissor
            1, // scissor_count
            asUnitArrayPtr(&render_area_),
        );

        const vertex_buffer_binding_count = 2;
        const vertex_buffer_binding_buffers = [vertex_buffer_binding_count]vk.Buffer {
            curves_buffer_.buffer,
            curves_buffer_.buffer,
        };
        const vertex_buffer_binding_offsets = [vertex_buffer_binding_count]vk.DeviceSize {
            curve_control_points_offset_in_buffer_,
            curve_colors_offset_in_buffer_,
        };
        vk_procs_.device.cmdBindVertexBuffers(
            command_buffer_,
            0, // first_binding
            vertex_buffer_binding_count, // binding_count
            &vertex_buffer_binding_buffers,
            &vertex_buffer_binding_offsets,
        );

        vk_procs_.device.cmdDraw(
            command_buffer_,
            6 * N_LINE_SEGMENTS_PER_CURVE, // vertex count
            @intCast(CURVE_COUNT), // instance count
            0, // first vertex
            0, // first instance
        );

        vk_procs_.device.cmdEndRenderPass(command_buffer_);
    }

    try vk_procs_.device.endCommandBuffer(command_buffer_);

    const render_submit_infos = [1]vk.SubmitInfo {
        .{
            .command_buffer_count = 1,
            .p_command_buffers = asUnitArrayPtr(&command_buffer_),
            .wait_semaphore_count = 1,
            .p_wait_semaphores = asUnitArrayPtr(&swapchain_image_acquired_semaphore_),
            .p_wait_dst_stage_mask = &[1]vk.PipelineStageFlags {
                .{ .color_attachment_output_bit = true },
            },
            .signal_semaphore_count = 1,
            .p_signal_semaphores = asUnitArrayPtr(&render_finished_semaphore_),
        }
    };
    try vk_procs_.device.queueSubmit(
        graphics_present_queue_,
        render_submit_infos.len,
        &render_submit_infos,
        command_buffer_pending_fence_,
    );

    // PRESENT -----------------------------------------------------------------------------------------------

    swapchain_.present(
        graphics_present_queue_,
        acquired_swapchain_image_index,
        asUnitArrayPtr(&render_finished_semaphore_),
    )
    catch |err| switch (err) {
        error.OutOfDateKHR => {
            log.debug("Attempted to present but swapchain is out of date; rebuilding", .{});
            const window_size = window_.getSize();
            try swapchain_.rebuild(vk.Extent2D { .width = window_size.width, .height = window_size.height });
            try updateStuffForNewSwapchain(swapchain_, render_pass_);
        },
        else => return err,
    };

    if (swapchain_.is_suboptimal) {
        log.debug("Swapchain is suboptimal; rebuilding", .{});
        const window_size = window_.getSize();
        try swapchain_.rebuild(vk.Extent2D { .width = window_size.width, .height = window_size.height });
        try updateStuffForNewSwapchain(swapchain_, render_pass_);
    }
}

fn init(allocator: Allocator, window_width: u32, window_height: u32) !void {
    
    glfw.setErrorCallback(glfwErrorCallback);
    if (!glfw.init(.{})) @panic("Failed to initialize GLFW");

    debug.assert(glfw.vulkanSupported());

    // Most Vulkan procedures must be dynamically loaded, so we need to get their addresses before we can use them.
    // The way the Vulkan spec (v1.3) expects us to do this is:
    // 1. Get the address of `vkGetInstanceProcAddr` in a platform-specific way.
    //     In this case, GLFW loads that symbol for us, and exposes it as `glfwGetInstanceProcAddress`.
    // 2. Use `vkGetInstanceProcAddr` to get procedures we need related to a Vulkan instance (e.g. `vkCreateInstance`).
    // 3. Use `vkGetInstanceProcAddr` to get other procedure locators, like `vkGetDeviceProcAddr`.
    // 4. Use `vkGetDeviceProcAddr` to get procedures we need related to a Vulkan device.
    //
    // If we didn't have GLFW to load the first symbol for us, we could have loaded the library using Linux's:
    // - dlopen() to load the library (people load "vulkan-1", but I have no idea where they got that name)
    // - dlsym() to get the address of each of the library's symbols that we intend to use
    // The Windows equivalents are `LoadLibrary` and `GetProcAddress`.
    //
    // @note: Since there may be multiple Vulkan implementations on a system (e.g. one for Intel integrated
    // graphics and one for a discrete Nvidia card), the spec says `vkGetInstanceProcAddr` may return a
    // pointer to a procedure that dispatches the intended procedure depending on the device, instead of a
    // pointer directly to the latter procedure. To avoid this overhead, we should use `vkGetDeviceProcAddr`
    // to get a pointer directly to the appropriate procedure.
    //
    // The Vulkan wrapper we're using provides a way to get many procedure addresses at a time. We must first
    // produce a struct definition whose members are the procedures we want, using
    // - vk.BaseWrapper(.{.createInstance = true, .otherProcWeWant = true, etc})
    // - vk.InstanceWrapper(.{...}) for procedures taking an instance as an argument
    // - vk.DeviceWrapper(.{...}) for procedures taking a device as an argument
    // These functions compute and return the appropriate struct type definitions.
    // Then we can use each struct's `.load()` procedure at runtime to load all their Vulkan proc addresses.
    const vkGetInstanceProcAddress: vk.PfnGetInstanceProcAddr = @ptrCast(&glfw.getInstanceProcAddress);
    vk_procs_.base = try vk_procs_.VulkanBaseProcs.load(vkGetInstanceProcAddress);

    // CREATE INSTANCE ---------------------------------------------------------------------------------------

    // "If successful the returned array will always include VK_KHR_surface".
    // "If it fails it will return NULL and GLFW will not be able to create Vulkan window surfaces."
    // - https://www.glfw.org/docs/latest/vulkan_guide.html (2023-05-14)
    // Presumably, this also includes VK_KHR_<wayland/xlib/xcb/win32>_surface when appropriate.
    const extensions_required_by_glfw = glfw.getRequiredInstanceExtensions() orelse @panic("GLFW can't create Vulkan window surfaces");

    // VK_LAYER_KHRONOS_validation isn't in the Vulkan spec (v1.3.234), but is provided by LunarG or something.
    // Fedora 37 provides them in the package `vulkan-validation-layers`.
    // @todo remove the ReleaseSafe condition iff it turns out these validation layers are too slow for ReleaseSafe
    const instance_layers = comptime switch (builtin.mode) {
        .Debug, .ReleaseSafe => [_][*:0]const u8 {"VK_LAYER_KHRONOS_validation"},
        .ReleaseFast, .ReleaseSmall => [_][*:0]u8 {},
    };

    const instance_info = vk.InstanceCreateInfo {
        .p_application_info = &vk.ApplicationInfo {
            .p_application_name = null,
            .application_version = 0,
            .api_version = VULKAN_VERSION,
            .engine_version = 0,
        },
        .enabled_layer_count = instance_layers.len,
        .pp_enabled_layer_names = &instance_layers,
        .enabled_extension_count = @intCast(extensions_required_by_glfw.len),
        .pp_enabled_extension_names = extensions_required_by_glfw.ptr,
    };
    const instance = try vk_procs_.base.createInstance(&instance_info, null);
    // @todo do we need to cast glfw.getInstanceProcAddress to another type?
    vk_procs_.instance = try vk_procs_.VulkanInstanceProcs.load(instance, vkGetInstanceProcAddress);

    // SELECT PHYSICAL DEVICE AND QUEUE FAMILIES -------------------------------------------------------------

    var physical_device_count: u32 = undefined;
    {
        const result = try vk_procs_.instance.enumeratePhysicalDevices(instance, &physical_device_count, null);
        if (result != .success) @panic("");
    }
    if (physical_device_count == 0) @panic("Found no Vulkan devices");
    //
    const physical_devices = try allocator.alloc(vk.PhysicalDevice, physical_device_count);
    defer allocator.free(physical_devices);
    {
        const result = try vk_procs_.instance.enumeratePhysicalDevices(
            instance,
            &physical_device_count,
            physical_devices.ptr,
        );
        if (result != .success) @panic("Unexpected result from Vulkan call");
    }
    
    // Device requirements: see `findRequiredQueueFamilies`
    // Device selection policy, for devices that satisfy requirements:
    // 1. first DISCRETE_GPU found
    // 2. otherwise first INTEGRATED_GPU found
    // 3. otherwise first device found (@todo maybe we can search farther, e.g. by preferring VIRTUAL_GPU over CPU)
    var physical_device: vk.PhysicalDevice = undefined;
    var physical_device_properties: vk.PhysicalDeviceProperties = undefined;
    var queue_family: u32 = undefined;
    var satisfactory_device_found = false;
    //
    for (physical_devices) |candidate_device| {
        // Vulkan 1.3 doesn't guarantee that there is a queue family with both present and graphics, but until
        // shown a counterexample, I am assuming that every implementation with a present family has a family
        // with both present and graphics.
        // @todo should we also check the PhysicalDeviceProperties.api_version as a compatibility requirement?
        const candidate_queue_family = try findSingleQueueFamilySatisfying(
            instance,
            candidate_device,
            .{ .graphics_bit = true },
            true, // `require_present_support`
            allocator,
        )
        orelse continue;

        // at this point, this candidate is satisfactory

        const candidate_properties = vk_procs_.instance.getPhysicalDeviceProperties(candidate_device);
        if (
            !satisfactory_device_found    // this is the first satisfactory candidate we found
            or deviceTypeIsBetter(candidate_properties.device_type, physical_device_properties.device_type)
        ) {
            satisfactory_device_found = true;
            physical_device = candidate_device;
            physical_device_properties = candidate_properties;
            queue_family = candidate_queue_family;
        }
    }
    //
    if (!satisfactory_device_found) @panic("No satisfactory graphics device found.");

    graphics_present_queue_family_index_ = queue_family;

    log.info("Selected device `{s}`", .{ physical_device_properties.device_name });

    // CREATE LOGICAL DEVICE AND QUEUES ----------------------------------------------------------------------

    // We're going with 1 queue total because some Intel integrated graphics cards only provide 1 queue
    // (including the one on my laptop, 2023-06-29).
    const queue_infos = [1]vk.DeviceQueueCreateInfo {
        .{
            .queue_family_index = queue_family,
            .queue_count = 1,
            .p_queue_priorities = &[1]f32 { 1.0 },
        }
    };

    const device_extensions = [_][*:0]const u8 { "VK_KHR_swapchain" };

    const device_info = vk.DeviceCreateInfo {
        // .p_next = &vk.PhysicalDeviceVulkan13Features { .inline_uniform_block = vk.TRUE },
        .queue_create_info_count = @intCast(queue_infos.len),
        .p_queue_create_infos = &queue_infos,
        //
        .enabled_extension_count = @intCast(device_extensions.len),
        .pp_enabled_extension_names = &device_extensions,
    };

    device_ = try vk_procs_.instance.createDevice(physical_device, &device_info, null);

    vk_procs_.device = try vk_procs_.VulkanDeviceProcs.load(
        device_,
        vk_procs_.instance.dispatch.vkGetDeviceProcAddr
    );

    graphics_present_queue_ = vk_procs_.device.getDeviceQueue(device_, queue_family, 0);

    // CREATE WINDOW AND SURFACE -----------------------------------------------------------------------------

    window_ = glfw.Window.create(
        window_width, window_height,
        "IT'S NOT A SCREENSAVER",
        null, null,
        glfw.Window.Hints {
            .client_api = .no_api, // disable OpenGL, since we're not using it
            .resizable = true,
        }
    )
    orelse @panic("Failed to create window");

    var window_surface: vk.SurfaceKHR = undefined;
    {
        const result = glfw.createWindowSurface(instance, window_, null, &window_surface);
        if (result != @intFromEnum(vk.Result.success)) @panic("Failed to create window surface");
    }

    // CREATE SWAPCHAIN --------------------------------------------------------------------------------------

    swapchain_ = try Swapchain.init(
        device_,
        physical_device,
        window_surface,
        vk.Extent2D { .width = window_width, .height = window_height },
        graphics_present_queue_family_index_,
        allocator,
    );

    // CREATE RENDER PASS ------------------------------------------------------------------------------------

    const render_pass_attachments = [1]vk.AttachmentDescription {
        .{
            .format = Swapchain.surface_format.format,
            .samples = vk.SampleCountFlags { .@"1_bit" = true },
            // @todo maybe we should use .clear for debugging purposes, and use .dont_care for ReleaseFast?
            // Although I imagine clearing is a very cheap operation.
            .load_op = .clear, // Clear "to a uniform value, which is specified when a render pass instance is begun"
            .store_op = .store,
            .stencil_load_op = .dont_care,  // not using
            .stencil_store_op = .dont_care, // not using
            .initial_layout = .undefined,
            .final_layout = .present_src_khr,
        }
    };
    const render_pass_swapchain_image_attachment: u32 = 0; // the index into `render_pass_attachments`

    const render_subpass_descriptions = [1]vk.SubpassDescription {
        .{
            .pipeline_bind_point = .graphics,
            .color_attachment_count = 1,
            .p_color_attachments = &[1]vk.AttachmentReference {
                .{
                    .attachment = render_pass_swapchain_image_attachment,
                    .layout = .color_attachment_optimal,
                },
            },
            .p_depth_stencil_attachment = null, // @todo didn't see the spec say that this can be null
        }
    };
    const the_only_render_subpass: u32 = 0; // index into `render_subpass_descriptions`

    const render_pass_info = vk.RenderPassCreateInfo {
        .attachment_count = @as(u32, render_pass_attachments.len),
        .p_attachments = &render_pass_attachments,
        .subpass_count = @as(u32, render_subpass_descriptions.len),
        .p_subpasses = &render_subpass_descriptions,
    };

    render_pass_ = try vk_procs_.device.createRenderPass(device_, &render_pass_info, null);

    // CREATE GRAPHICS PIPELINE ------------------------------------------------------------------------------

    // shader modules can be destroyed after the pipelines that use them are created
    const vertex_shader_module = try util.createShaderModule(device_, &shaders.vertex_shader, null);
    defer vk_procs_.device.destroyShaderModule(device_, vertex_shader_module, null);
    //
    const fragment_shader_module = try util.createShaderModule(device_, &shaders.fragment_shader, null);
    defer vk_procs_.device.destroyShaderModule(device_, fragment_shader_module, null);

    const vertex_shader_specialization_constants = VertexShaderSpecializationConstants {
        .camera_center_x = WORLD_SIZE_X*0.5,
        .camera_center_y = WORLD_SIZE_Y*0.5,
        .camera_halfsize_x = WORLD_SIZE_X*0.5,
        .camera_halfsize_y = WORLD_SIZE_Y*0.5,
        .n_line_segments_per_curve = N_LINE_SEGMENTS_PER_CURVE,
        .line_thickness = LINE_THICKNESS,
    };
    const vertex_spec_constants_map_entries = [_]vk.SpecializationMapEntry {
        .{
            .constant_id = 0,
            .offset = @offsetOf(VertexShaderSpecializationConstants, "camera_center_x"),
            .size = @sizeOf(@TypeOf(vertex_shader_specialization_constants.camera_center_x)),
        },
        .{
            .constant_id = 1,
            .offset = @offsetOf(VertexShaderSpecializationConstants, "camera_center_y"),
            .size = @sizeOf(@TypeOf(vertex_shader_specialization_constants.camera_center_y)),
        },
        .{
            .constant_id = 2,
            .offset = @offsetOf(VertexShaderSpecializationConstants, "camera_halfsize_x"),
            .size = @sizeOf(@TypeOf(vertex_shader_specialization_constants.camera_halfsize_x)),
        },
        .{
            .constant_id = 3,
            .offset = @offsetOf(VertexShaderSpecializationConstants, "camera_halfsize_y"),
            .size = @sizeOf(@TypeOf(vertex_shader_specialization_constants.camera_halfsize_y)),
        },

        .{
            .constant_id = 4,
            .offset = @offsetOf(VertexShaderSpecializationConstants, "n_line_segments_per_curve"),
            .size = @sizeOf(@TypeOf(vertex_shader_specialization_constants.n_line_segments_per_curve)),
        },
        .{
            .constant_id = 5,
            .offset = @offsetOf(VertexShaderSpecializationConstants, "line_thickness"),
            .size = @sizeOf(@TypeOf(vertex_shader_specialization_constants.line_thickness)),
        },
    };

    const shader_stage_infos = [_]vk.PipelineShaderStageCreateInfo {
        // vertex shader
        .{
            .stage = .{ .vertex_bit = true },
            .module = vertex_shader_module,
            .p_name = "main",
            .p_specialization_info = &vk.SpecializationInfo {
                .map_entry_count = vertex_spec_constants_map_entries.len,
                .p_map_entries = &vertex_spec_constants_map_entries,
                .data_size = @sizeOf(VertexShaderSpecializationConstants),
                .p_data = &vertex_shader_specialization_constants,
            },
        },
        // fragment shader
        .{
            .stage = .{ .fragment_bit = true },
            .module = fragment_shader_module,
            .p_name = "main",
        },
    };


    const vertex_attribute_descriptions = [_]vk.VertexInputAttributeDescription {
        .{
            .location = 0,
            .binding = 0,
            .format = CurveControlPoints.pos_format,
            .offset = @offsetOf(CurveControlPoints, "point_1_pos"),
        },
        .{
            .location = 1,
            .binding = 0,
            .format = CurveControlPoints.pos_format,
            .offset = @offsetOf(CurveControlPoints, "point_2_pos"),
        },
        .{
            .location = 2,
            .binding = 0,
            .format = CurveControlPoints.pos_format,
            .offset = @offsetOf(CurveControlPoints, "point_3_pos"),
        },
        .{
            .location = 3,
            .binding = 0,
            .format = CurveControlPoints.pos_format,
            .offset = @offsetOf(CurveControlPoints, "point_4_pos"),
        },

        .{
            .location = 4,
            .binding = 1,
            .format = CurveColors.color_format,
            .offset = @offsetOf(CurveColors, "start_color"),
        },
        .{
            .location = 5,
            .binding = 1,
            .format = CurveColors.color_format,
            .offset = @offsetOf(CurveColors, "end_color"),
        },
    };

    const vertex_binding_descriptions = [2]vk.VertexInputBindingDescription {
        .{
            .binding = 0,
            .stride = @sizeOf(CurveControlPoints),
            .input_rate = .instance,
        },
        .{
            .binding = 1,
            .stride = @sizeOf(CurveColors),
            .input_rate = .instance,
        },
    };

    const vertex_input_state_info = vk.PipelineVertexInputStateCreateInfo {
        .vertex_binding_description_count = vertex_binding_descriptions.len,
        .p_vertex_binding_descriptions = &vertex_binding_descriptions,
        .vertex_attribute_description_count = vertex_attribute_descriptions.len,
        .p_vertex_attribute_descriptions = &vertex_attribute_descriptions,
    };


    const input_assembly_state_info = vk.PipelineInputAssemblyStateCreateInfo {
        .topology = .triangle_list,
        .primitive_restart_enable = vk.FALSE,
    };


    // "Vulkan Tutorial" (by Alexander Overvoorde) has some good images explaining viewports and scissors.
    //
    // Viewport: the subregion of the framebuffer to which to render.
    // The image is transformed into these coordinates before rasterization.
    // Regardless of the position or shape of the viewport, the same image is rendered into it; it's just
    // stretched or squished in each dimension to fit.
    //
    // Scissor region: any pixels outside the scissor region aren't written to the framebuffer, even if
    // they're in the viewport.
    const viewport_state_info = vk.PipelineViewportStateCreateInfo {
        .viewport_count = 1,
        .p_viewports = null, // using dynamic viewport
        .scissor_count = 1,
        .p_scissors = null, // using dynamic scissor
    };


    const rasterization_state_info = vk.PipelineRasterizationStateCreateInfo {
        .depth_clamp_enable = vk.FALSE,
        .rasterizer_discard_enable = vk.FALSE, // @todo haven't really thought about this
        .polygon_mode = .fill,
        .cull_mode = .{}, // 2D, I don't have a concept of "front" or "back" faces
        .front_face = .counter_clockwise,

        // not using depth bias
        .depth_bias_enable = vk.FALSE,
        .depth_bias_constant_factor = 0.0,
        .depth_bias_clamp = 0.0,
        .depth_bias_slope_factor = 0.0,

        .line_width = 1.0, // unused, we're drawing lines ourselves by rendering rectangles
    };


    const multisample_state_info = vk.PipelineMultisampleStateCreateInfo {
        .rasterization_samples = vk.SampleCountFlags { .@"1_bit" = true },
        .sample_shading_enable = vk.FALSE,
        .min_sample_shading = 0.0,
        .p_sample_mask = null,
        .alpha_to_coverage_enable = vk.FALSE,
        .alpha_to_one_enable = vk.FALSE,
    };


    // Not using stencil, these are all placeholder values
    const placeholder_stencil_op_state = vk.StencilOpState {
        .fail_op = .keep,
        .pass_op = .keep,
        .depth_fail_op = .keep,
        .compare_op = .never,
        .compare_mask = 0,
        .write_mask = 0,
        .reference = 0,
    };
    const depth_stencil_state_info = vk.PipelineDepthStencilStateCreateInfo {
        .depth_test_enable = vk.FALSE,
        .depth_write_enable = vk.FALSE,
        .depth_compare_op = .never,
        .depth_bounds_test_enable = vk.FALSE,
        .stencil_test_enable = vk.FALSE,
        .front = placeholder_stencil_op_state,
        .back  = placeholder_stencil_op_state,
        .min_depth_bounds = 0.0,
        .max_depth_bounds = 0.0,
    };


    const pipeline_color_blend_attachment_states = [1]vk.PipelineColorBlendAttachmentState {
        .{
            .blend_enable = vk.FALSE,
            .src_color_blend_factor = .one,
            .dst_color_blend_factor = .zero,
            .color_blend_op = .add,
            .src_alpha_blend_factor = .one,
            .dst_alpha_blend_factor = .zero,
            .alpha_blend_op = .add,
            .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true },
        }
    };

    // reference: Vk spec 1.3.234, chapter 29.1 "Blending"
    const color_blend_state_info = vk.PipelineColorBlendStateCreateInfo {
        .logic_op_enable = vk.FALSE,
        .logic_op = .clear, // placeholder value, since .logic_op_enable = false
        .attachment_count = pipeline_color_blend_attachment_states.len,
        .p_attachments = &pipeline_color_blend_attachment_states,
        // not used as long as the attachment state blend factors are .one and .zero
        .blend_constants = [4]f32 { 0.0, 0.0, 0.0, 0.0 },
    };


    // Make viewport and scissor dynamic, so that we don't have to recreate the pipeline when we change them
    // due to resized window
    const dynamic_states = [_]vk.DynamicState { .viewport, .scissor };
    const dynamic_state_info = vk.PipelineDynamicStateCreateInfo {
        .dynamic_state_count = dynamic_states.len,
        .p_dynamic_states = &dynamic_states,
    };


    const graphics_pipeline_layout_info = vk.PipelineLayoutCreateInfo {};

    pipeline_layout_ = try vk_procs_.device.createPipelineLayout(
        device_,
        &graphics_pipeline_layout_info,
        null
    );


    const graphics_pipeline_info = vk.GraphicsPipelineCreateInfo {
        .stage_count = shader_stage_infos.len,
        .p_stages = &shader_stage_infos,
        .p_vertex_input_state = &vertex_input_state_info,
        .p_input_assembly_state = &input_assembly_state_info,
        .p_viewport_state = &viewport_state_info,
        .p_rasterization_state = &rasterization_state_info,
        .p_multisample_state = &multisample_state_info,
        .p_depth_stencil_state = &depth_stencil_state_info,
        .p_color_blend_state = &color_blend_state_info,
        .p_dynamic_state = &dynamic_state_info,
        .layout = pipeline_layout_,
        .render_pass = render_pass_,
        .subpass = the_only_render_subpass,
        .base_pipeline_handle = .null_handle,
        .base_pipeline_index = -1, // presumably unused as long as .base_pipeline_handle is .null_handle
    };

    {
        const result = try vk_procs_.device.createGraphicsPipelines(
            device_,
            vk.PipelineCache.null_handle,
            1,
            asUnitArrayPtr(&graphics_pipeline_info),
            null,
            asUnitArrayPtr(&pipeline_),
        );
        if (result != .success) @panic("VkResult != VK_SUCCESS after supposedly successful pipeline creation");
    }

    // CREATE FRAMEBUFFERS -----------------------------------------------------------------------------------

    swapchain_images_scratch_ = ArrayList(vk.Image).init(allocator);
    swapchain_image_views_ = ArrayList(vk.ImageView).init(allocator);
    swapchain_framebuffers_ = ArrayList(vk.Framebuffer).init(allocator);
    try updateStuffForNewSwapchain(swapchain_, render_pass_);

    // CREATE COMMAND BUFFERS --------------------------------------------------------------------------------

    const command_pool_info = vk.CommandPoolCreateInfo {
        .flags = .{ .reset_command_buffer_bit = true },
        .queue_family_index = queue_family,
    };

    const command_pool = try vk_procs_.device.createCommandPool(device_, &command_pool_info, null);


    const graphics_command_buffer_allocate_info = vk.CommandBufferAllocateInfo {
        .command_pool = command_pool,
        .level = .primary,
        .command_buffer_count = 1,
    };

    var graphics_command_buffers: [1]vk.CommandBuffer = undefined;
    try vk_procs_.device.allocateCommandBuffers(
        device_,
        &graphics_command_buffer_allocate_info,
        &graphics_command_buffers,
    );

    command_buffer_ = graphics_command_buffers[0];

    // CREATE SYNCHRONIZATION PRIMITIVES ---------------------------------------------------------------------

    swapchain_image_acquired_semaphore_ = try vk_procs_.device.createSemaphore(device_, &.{}, null);

    render_finished_semaphore_ = try vk_procs_.device.createSemaphore(device_, &.{}, null);

    command_buffer_pending_fence_ = try vk_procs_.device.createFence(
        device_,
        &.{ .flags = .{ .signaled_bit = true } },
        null,
    );

    // ALLOCATE CURVE INSTANCES ------------------------------------------------------------------------------

    curve_control_points_ = try allocator.alloc(CurveControlPoints, CURVE_COUNT);
    curve_colors_ = try allocator.alloc(CurveColors, CURVE_COUNT);


    const curve_control_points_size = CURVE_COUNT*@sizeOf(CurveControlPoints);
    const curve_control_points_plus_padding_size =
        util.roundUpToMultipleOf(usize, curve_control_points_size, @alignOf(CurveColors));
    const curve_colors_size = CURVE_COUNT*@sizeOf(CurveColors);
    const curves_buffer_size = curve_control_points_plus_padding_size + curve_colors_size;

    const curves_buffer_info = vk.BufferCreateInfo {
        .size = curves_buffer_size,
        .usage = .{ .vertex_buffer_bit = true },
        .sharing_mode = .exclusive,
        .queue_family_index_count = 1,
        .p_queue_family_indices = &[1]u32 { queue_family },
    };
    const curves_buffer = try vk_procs_.device.createBuffer(device_, &curves_buffer_info, null);

    const curves_buffer_mem_requirements = vk_procs_.device.getBufferMemoryRequirements(
        device_,
        curves_buffer,
    );


    const device_memory_properties = vk_procs_.instance.getPhysicalDeviceMemoryProperties(physical_device);

    const device_memory = try vk_procs_.device.allocateMemory(
        device_,
        &.{

            .allocation_size = curves_buffer_mem_requirements.size,

            .memory_type_index = firstMemoryTypeSatisfying(
                // @todo if you can't determine the cause of a memory bug, consider adding `.host_coherent_bit` here
                .{ .host_visible_bit = true },
                device_memory_properties,
            ) orelse @panic("Failed to find desired memory type"),

        },
        null,
    );


    try vk_procs_.device.bindBufferMemory(device_, curves_buffer, device_memory, 0);

    curves_buffer_ = AllocatedBuffer {
        .buffer = curves_buffer,
        .size = curves_buffer_info.size,
        .backing_memory = device_memory,
        .offset_in_memory = 0,
    };
    curve_control_points_offset_in_buffer_ = 0;
    curve_colors_offset_in_buffer_ = curve_control_points_plus_padding_size;


    // keeping this persistently-mapped
    const mapped_mem_ptr: [*]u8 = blk: {

        const ptr: *anyopaque = try vk_procs_.device.mapMemory(
            device_,
            curves_buffer_.backing_memory,
            curves_buffer_.offset_in_memory,
            curves_buffer_.size,
            .{},
        )
        orelse @panic("`vkMapMemory` returned a null pointer");

        break :blk @ptrCast(ptr);
    };

    // @note relies on the fact that this VkBuffer has offset 0 in this VkMemory
    mapped_curve_control_points_ptr_ = mapped_mem_ptr + curve_control_points_offset_in_buffer_;
    mapped_curve_colors_ptr_ = mapped_mem_ptr + curve_colors_offset_in_buffer_;
}

/// Returns null if not found.
fn findSingleQueueFamilySatisfying(
    instance: vk.Instance,
    device: vk.PhysicalDevice,
    required_flags: vk.QueueFlags,
    require_present_support: bool,
    allocator: Allocator,
) error{OutOfMemory}!?u32 {

    var queue_family_count: u32 = undefined;
    vk_procs_.instance.getPhysicalDeviceQueueFamilyProperties(device, &queue_family_count, null);
    //
    const properties_list = try allocator.alloc(vk.QueueFamilyProperties, queue_family_count);
    defer allocator.free(properties_list);
    vk_procs_.instance.getPhysicalDeviceQueueFamilyProperties(
        device,
        &queue_family_count,
        properties_list.ptr,
    );

    for (properties_list, 0..) |family_properties, fam| {
        const family: u32 = @intCast(fam);

        const satisfies_flags = family_properties.queue_flags.contains(required_flags);
        if (!satisfies_flags) continue;

        if (require_present_support) {
            const supports_present = glfw.getPhysicalDevicePresentationSupport(
                @ptrFromInt(@intFromEnum(instance)), // @todo extremely sus casting, how do you know that the handle is a pointer?
                @ptrFromInt(@intFromEnum(device)),   // @todo extremely sus casting, how do you know that the handle is a pointer?
                family,
            );
            if (!supports_present) continue;
        }

        return family;
    }

    return null;
}

/// True iff `dev1` > `dev2`, according to the ordering:
///     DISCRETE_GPU > INTEGRATED_GPU > everything else
/// This implies that comparing two devices in the same category will return False.
fn deviceTypeIsBetter(dev1: vk.PhysicalDeviceType, dev2: vk.PhysicalDeviceType) bool {
    // @note This implementation relies on the PhysicalDeviceType enum values specified in VK spec v1.3.234.
    // Uses the PhysicalDeviceType enum as an index.
    const device_type_priorities = comptime [5]u8 {
        // @debug temporarily sticking with integrated GPU, because the Nvidia GPU sometimes freezes my
        // display until I restart my laptop if I fuck something up
        0, // 0: OTHER
        2, // 1: INTEGRATED_GPU
        1, // 2: DISCRETE_GPU
        0, // 3: VIRTUAL_GPU
        0, // 4: CPU
    };

    const dev1_index: u32 = @intCast(@intFromEnum(dev1));
    const dev2_index: u32 = @intCast(@intFromEnum(dev2));

    // sanity check
    if (comptime (builtin.mode == .Debug or builtin.mode == .ReleaseSafe)) {
        if (dev1_index > 5 or dev2_index > 5) @panic("Encountered invalid device type");
    }

    return device_type_priorities[dev1_index] > device_type_priorities[dev2_index];
}

/// Use after rebuilding the swapchain.
fn updateStuffForNewSwapchain(
    swapchain: Swapchain,
    render_pass: vk.RenderPass,
) !void {

    render_area_ = getRenderArea_16x9(swapchain.extent);

    for (swapchain_framebuffers_.items) |buf| vk_procs_.device.destroyFramebuffer(device_, buf, null);
    for (swapchain_image_views_.items) |view| vk_procs_.device.destroyImageView(device_, view, null);

    try swapchain.getImages(&swapchain_images_scratch_);
    const image_count = swapchain_images_scratch_.items.len;

    try swapchain_image_views_.resize(image_count);
    try swapchain_framebuffers_.resize(image_count);
    for (0..image_count) |image_index| {

        const image_view_info = vk.ImageViewCreateInfo {
            .image = swapchain_images_scratch_.items[image_index],
            .view_type = .@"2d",
            .format = Swapchain.surface_format.format,
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
        const image_view = try vk_procs_.device.createImageView(device_, &image_view_info, null);

        const framebuffer_info = vk.FramebufferCreateInfo {
            .render_pass = render_pass,
            .attachment_count = 1,
            .p_attachments = asUnitArrayPtr(&image_view),
            .width  = swapchain.extent.width,
            .height = swapchain.extent.height,
            .layers = 1,
        };
        const framebuffer = try vk_procs_.device.createFramebuffer(device_, &framebuffer_info, null);

        swapchain_image_views_.items[image_index] = image_view;
        swapchain_framebuffers_.items[image_index] = framebuffer;
    }
}

/// Returns a 16:9 subregion of a swapchain image, which:
/// - maximizes the subregion's area
/// - is centered in the image
fn getRenderArea_16x9(swapchain_extent: vk.Extent2D) vk.Rect2D {
    const swapchain_width  = swapchain_extent.width;
    const swapchain_height = swapchain_extent.height;

    const Dim = enum { x, y };
    const limiting_swapchain_dimension: Dim = if (swapchain_width * 9 <= swapchain_height * 16) .x else .y;

    var render_area_width:  u32 = undefined;
    var render_area_height: u32 = undefined;
    var render_area_offset_x: i32 = undefined;
    var render_area_offset_y: i32 = undefined;
    switch (limiting_swapchain_dimension) {
        .x => {
            render_area_width = swapchain_width;
            render_area_height = render_area_width * 9 / 16;
            render_area_offset_x = 0;
            render_area_offset_y = @intCast((swapchain_height - render_area_height) / 2);
        },
        .y => {
            render_area_height = swapchain_height;
            render_area_width = render_area_height * 16 / 9;
            render_area_offset_y = 0;
            render_area_offset_x = @intCast((swapchain_width - render_area_width) / 2);
        },
    }

    return vk.Rect2D {
        .offset = .{
            .x = render_area_offset_x,
            .y = render_area_offset_y,
        },
        .extent = .{
            .width = render_area_width,
            .height = render_area_height,
        },
    };
}

/// This is supposed to be useful while the user is resizing the window; a new swapchain might be invalidated
/// immediately after rebuilding because the window is still being resized, so this just keeps rebuilding
/// the swapchain until it's no longer out-of-date.
fn acquireNextImage_rebuildSwapchainUntilSuccess(
    swapchain: *Swapchain,
    signal_semaphore: vk.Semaphore,
    signal_fence: vk.Fence,
) u32 {
    // This procedure relies on error.OutOfDate being the only possible error (for readability+laziness).
    // This check is here detect if that changes, so that we can fix this procedure accordingly.
    comptime {
        const RetType = @typeInfo(@TypeOf(Swapchain.acquireNextImage)).Fn.return_type.?;
        if (@typeInfo(RetType).ErrorUnion.error_set != error{OutOfDate}) @compileError("Unexpected error set");
    }

    var image_index = swapchain.acquireNextImage(signal_semaphore, signal_fence);
    if (image_index) |index| return index
    else |_| {} // continue

    // SWAPCHAIN MUST BE REBUILT -----------------------------------------------------------------------------

    var n_times_rebuilt: usize = 0;
    while (image_index == error.OutOfDate) {
        log.debug("Swapchain out of date, rebuilding (attempt {})", .{ n_times_rebuilt });

        const window_size = window_.getSize();
        swapchain.rebuild(.{ .width = window_size.width, .height = window_size.height})
        catch @panic("Failed to rebuild swapchain");

        n_times_rebuilt += 1;

        image_index = swapchain.acquireNextImage(signal_semaphore, signal_fence);
    }

    updateStuffForNewSwapchain(swapchain_, render_pass_)
    catch @panic("Successfully rebuilt swapchain, but failed to update stuff after that");

    return image_index catch unreachable;
}

/// Returns an index to the first element in `mem_props.memory_types` that satisfies `required_flags`.
/// `null` iff no such memory type found.
fn firstMemoryTypeSatisfying(
    required_flags: vk.MemoryPropertyFlags,
    mem_props: vk.PhysicalDeviceMemoryProperties,
) ?u32 {
    for (0..mem_props.memory_type_count) |mem_type_index| {
        const mem_type = mem_props.memory_types[mem_type_index];
        if (mem_type.property_flags.contains(required_flags)) return @intCast(mem_type_index);
    }
    return null;
}

fn glfwErrorCallback(_: glfw.ErrorCode, description: [:0]const u8) void {
    const glfw_log = comptime std.log.scoped(.glfw);
    glfw_log.warn("{s}", .{ description });
}

//
// ===========================================================================================================
//

const VertexShaderSpecializationConstants = extern struct {
    camera_center_x: f32,
    camera_center_y: f32,
    camera_halfsize_x: f32,
    camera_halfsize_y: f32,
    n_line_segments_per_curve: u32,
    line_thickness: f32,
};

const CurveControlPoints = extern struct {
    point_1_pos: @Vector(2, f32) align(8),
    point_2_pos: @Vector(2, f32),
    point_3_pos: @Vector(2, f32),
    point_4_pos: @Vector(2, f32),

    pub const pos_format = vk.Format.r32g32_sfloat;
};
comptime { util.assertAlignment(8, CurveControlPoints); }
comptime { util.assertSize(8*4, CurveControlPoints); }

const CurveColors = extern struct {
    start_color: [4]u8 align(4),
    end_color: [4]u8,

    pub const color_format = vk.Format.r8g8b8a8_unorm;
};
comptime { util.assertAlignment(4, CurveColors); }
comptime { util.assertSize(8, CurveColors); }

const AllocatedBuffer = struct {
    buffer: vk.Buffer,
    size: vk.DeviceSize,
    backing_memory: vk.DeviceMemory,
    offset_in_memory: vk.DeviceSize,
};
