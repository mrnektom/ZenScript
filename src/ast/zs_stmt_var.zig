const std = @import("std");
const Expr = @import("zs_expr.zig").ZSExpr;

type: VariableType,
name: []const u8,
expr: Expr,

pub const VariableType = enum {
    Const,
    Let,
};

pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
    std.debug.print("Deinit: {s}\n", .{@typeName(@This())});
    self.expr.deinit(allocator);
}
