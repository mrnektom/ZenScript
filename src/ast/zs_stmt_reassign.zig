const std = @import("std");
const Expr = @import("zs_expr.zig").ZSExpr;

name: []const u8,
expr: Expr,

pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
    self.expr.deinit(allocator);
}
