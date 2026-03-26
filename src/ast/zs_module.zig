const std = @import("std");
const ast = @import("ast_node.zig");
const zs_import = @import("zs_import.zig");

pub const ImportedSymbol = zs_import.ImportedSymbol;

pub const ZSModule = struct {
    deps: []ZSModuleDep,
    ast: []ast.ZSAstNode,
    filename: []const u8,
    source: []const u8,

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
    symbols: []ImportedSymbol,
};
