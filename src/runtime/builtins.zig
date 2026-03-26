const std = @import("std");
const llvm = @import("llvm");
const core = llvm.core;
const engine = llvm.engine;
const types = llvm.types;

const ZSString = extern struct {
    len: i32,
    ptr: [*]const u8,
};

fn zsPrint(s: ZSString) callconv(.c) void {
    const len: usize = @intCast(s.len);
    const slice = s.ptr[0..len];
    const stdout = std.fs.File.stdout();
    stdout.writeAll(slice) catch {};
    stdout.writeAll("\n") catch {};
}

fn zsPrintNumber(n: i32) callconv(.c) void {
    const stdout = std.fs.File.stdout();
    var buf: [20]u8 = undefined;
    const slice = std.fmt.bufPrint(&buf, "{d}", .{n}) catch return;
    stdout.writeAll(slice) catch {};
    stdout.writeAll("\n") catch {};
}

const Builtin = struct {
    name: [*:0]const u8,
    ptr: *const anyopaque,
};

const builtins = [_]Builtin{
    .{ .name = "print", .ptr = @ptrCast(&zsPrint) },
    .{ .name = "print_number", .ptr = @ptrCast(&zsPrintNumber) },
};

pub fn registerBuiltins(ee: types.LLVMExecutionEngineRef, module: types.LLVMModuleRef) void {
    for (builtins) |b| {
        const func = core.LLVMGetNamedFunction(module, b.name);
        if (func != null) {
            engine.LLVMAddGlobalMapping(ee, func, @ptrFromInt(@intFromPtr(b.ptr)));
        }
    }
}
