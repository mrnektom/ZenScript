const std = @import("std");
const Expr = @import("zs_expr.zig").ZSExpr;

subject: *const Expr,
arguments: []Expr,

pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
    std.debug.print("Deinit: {s}\n", .{@typeName(@This())});
    allocator.free(@as([]Expr, @ptrCast(@constCast(self.subject))));
    allocator.free(self.arguments);
}
