const std = @import("std");
const Expr = @import("zs_expr.zig").ZSExpr;

subject: *const Expr,
arguments: []Expr,
startPos: usize,
endPos: usize,

pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
    for (self.arguments) |arg| {
        arg.deinit(allocator);
    }
    self.subject.deinit(allocator);
    allocator.free(@as([]Expr, @ptrCast(@constCast(self.subject))));
    allocator.free(self.arguments);
}
