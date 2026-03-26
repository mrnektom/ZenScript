const std = @import("std");
const Expr = @import("zs_expr.zig").ZSExpr;
const stmt = @import("zs_stmt.zig");

type: VariableType,
name: []const u8,
expr: Expr,
modifiers: stmt.Modifiers,

pub const VariableType = enum {
    Const,
    Let,
};

pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
    self.expr.deinit(allocator);
}
