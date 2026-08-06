const std = @import("std");
const runtime_mod = @import("../core/runtime.zig");

const gpa_state = struct {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
};

fn cAllocator() std.mem.Allocator {
    return gpa_state.gpa.allocator();
}

pub const zr_runtime = opaque {};

export fn zr_version_major() c_uint {
    return 0;
}
export fn zr_version_minor() c_uint {
    return 7;
}
export fn zr_version_patch() c_uint {
    return 0;
}

export fn zr_runtime_create(workers: c_uint) ?*zr_runtime {
    const alloc = cAllocator();
    const rt = alloc.create(runtime_mod.Runtime) catch return null;
    rt.* = runtime_mod.Runtime.init(alloc, .{
        .workers = workers,
        .stack_pool = true,
        .io = .none,
    }) catch {
        alloc.destroy(rt);
        return null;
    };
    return @ptrCast(rt);
}

export fn zr_runtime_destroy(handle: ?*zr_runtime) void {
    const h = handle orelse return;
    const rt: *runtime_mod.Runtime = @ptrCast(@alignCast(h));
    const alloc = rt.allocator;
    rt.deinit();
    alloc.destroy(rt);
}

export fn zr_runtime_run(handle: ?*zr_runtime) c_int {
    const h = handle orelse return -1;
    const rt: *runtime_mod.Runtime = @ptrCast(@alignCast(h));
    rt.run() catch return -1;
    return 0;
}
