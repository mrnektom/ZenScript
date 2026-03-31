const ast = @import("ast_node.zig");

name: []const u8,
type_params: []const []const u8,
args: []Arg,
ret: ?ast.ZSType,
modifiers: ast.stmt.Modifiers,
body: ?ast.expr.ZSExpr,

pub const Arg = struct {
    name: []const u8,
    type: ?ast.ZSType,
};
