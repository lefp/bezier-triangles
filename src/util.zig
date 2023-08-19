const vk_procs = @import("vulkan_procedures.zig");
const vk = @import("vulkan");
const std = @import("std");

const debug = std.debug;
const fmt = std.fmt;
const testing = std.testing;

//
// ===========================================================================================================
//

/// Casts an *T to *[1]T, and *const T to *const [1]T.
pub fn asUnitArrayPtr(ptr: anytype) type_blk: {
    const ptr_type_info = @typeInfo(@TypeOf(ptr)).Pointer;

    if (ptr_type_info.size != .One) @compileError("`asPtrToUnitArray` expects single-item pointer as input");

    const ElemType = ptr_type_info.child;
    const is_const_ptr = ptr_type_info.is_const;

    break :type_blk if (is_const_ptr) *const [1]ElemType else *[1]ElemType;
} {
    return ptr;
}

pub fn waitForFenceBlocking(device: vk.Device, fence: *const vk.Fence) !void {
    const result = try vk_procs.device.waitForFences(
        device,
        1,
        asUnitArrayPtr(fence),
        vk.TRUE,
        std.math.maxInt(u64),
    );
    if (result != .success) debug.panic("vkWaitForFences returned {s}", .{ @tagName(result) });
}

pub fn assertAlignment(comptime expected_alignment: comptime_int, comptime T: type) void {

    const actual_alignment = @alignOf(T);
    if (actual_alignment != expected_alignment) {

        const err_msg = fmt.comptimePrint(
            "Assertion failed: {s} has alignment {}, but expected {}",
            .{ @typeName(T), actual_alignment, expected_alignment },
        );

        @compileError(err_msg);
    }
}
pub fn assertSize(comptime expected_size: comptime_int, comptime T: type) void {
    
    const actual_size = @sizeOf(T);
    if (actual_size != expected_size) {

        const err_msg = fmt.comptimePrint(
            "Assertion failed: {s} has size {}, but expected {}",
            .{ @typeName(T), actual_size, expected_size },
        );

        @compileError(err_msg);
    }
}

// SPIRV spec (v1.6 revision 2):
// - "a SPIR-V module is a single linear stream of words"
// - "Word: 32 bits."
pub fn createShaderModule(
    device: vk.Device,
    spirv_bytes: []align(@alignOf(u32)) const u8,
    p_allocator: ?*vk.AllocationCallbacks,
) !vk.ShaderModule {
    std.debug.assert(spirv_bytes.len % @sizeOf(u32) == 0);

    const shader_module_info = vk.ShaderModuleCreateInfo {
        .code_size = spirv_bytes.len, // "size, IN BYTES" - Vk spec 1.3
        .p_code = @ptrCast(spirv_bytes.ptr),
    };

    return vk_procs.device.createShaderModule(device, &shader_module_info, p_allocator);
    // if we add more code to this procedure, errdefer destroyShaderModule if appropriate
}

/// Call as follows: `panicLocation(@src())`.
/// Useful when you want to panic, *without* specifying a specific error message (for uncluttered code), but
/// still want to know where the panic happened even when debug info is stripped (e.g. in a production build).
pub fn panicLoc(comptime location: std.builtin.SourceLocation) noreturn {
    @setCold(true);
    debug.panic("file {s}, line {}", .{ location.file, location.line });
}

pub fn panicLocErr(comptime location: std.builtin.SourceLocation, err: anyerror) noreturn {
    @setCold(true);
    debug.panic("file {s}, line {}, error `{s}`", .{ location.file, location.line, @errorName(err) });
}

pub fn panicLocMsg(comptime location: std.builtin.SourceLocation, message: []const u8) noreturn {
    @setCold(true);
    debug.panic("file {s}, line {}, message `{s}`", .{ location.file, location.line, message });
}

/// Round up an unsigned integer.
/// `multiple_of` must not be 0.
pub fn roundUpToMultipleOf(comptime T: type, number_to_round: T, multiple_of: T) T {
    comptime {
        const type_info = @typeInfo(T);
        if (type_info != .Int or type_info.Int.signedness != .unsigned) @compileError("`T` must be an unsigned integer type");
    }
    debug.assert(multiple_of != 0);

    return ((number_to_round + multiple_of - 1) / multiple_of) * multiple_of;
}
test "roundUpToMultipleOf" {
    for ([_]u32 { 3, 4, 8 }) |divisor| {
        try testing.expect(roundUpToMultipleOf(u32, 0, divisor) == 0);
        for (1..divisor) |val| try testing.expect(
            roundUpToMultipleOf(u32, @as(u32, @intCast(val)), divisor) == divisor
        );
    }
    for ([_]u32 { 0, 1, 3, 4, 8 }) |val| try testing.expect(roundUpToMultipleOf(u32, val, 1) == val);
    try testing.expect(roundUpToMultipleOf(u32, 75, 4) == 76);
    try testing.expect(roundUpToMultipleOf(u32, 0, 16) == 0);
}