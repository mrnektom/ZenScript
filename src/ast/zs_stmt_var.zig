const std = @import("std");
const Expr = @import("zs_expr.zig").ZSExpr;
const stmt = @import("zs_stmt.zig");
const type_notation = @import("zs_type_notation.zig");

type: VariableType,
name: []const u8,
expr: Expr,
modifiers: stmt.Modifiers,
type_annotation: ?type_notation.ZSType = null,

pub const VariableType = enum {
    Const,
    Let,
};

pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
    self.expr.deinit(allocator);
    if (self.type_annotation) |*ta| {
        @constCast(ta).deinit(allocator);
    }
}
