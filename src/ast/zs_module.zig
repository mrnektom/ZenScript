const std = @import("std");
const ast = @import("ast_node.zig");

pub const ZSModule = struct {
    deps: []ZSModuleDep,
    ast: []ast.ZSAstNode,

    pub fn deinit(self: *const ZSModule, allocator: std.mem.Allocator) void {
        for (self.ast) |node| {
            node.deinit(allocator);
        }
        allocator.free(self.ast);
        allocator.free(self.deps);
    }
};

pub const ZSModuleDep = struct {
    path: []const u8,
    symbols: [][]const u8,
};

const ZSAstType = enum {
    variable,
    expr,
};
