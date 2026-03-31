const std = @import("std");
const Expr = @import("zs_expr.zig").ZSExpr;

pub const ReassignTarget = union(enum) {
    name: []const u8,
    index: IndexTarget,
};

pub const IndexTarget = struct {
    subject_name: []const u8,
    index: Expr,
    startPos: usize,
};

target: ReassignTarget,
expr: Expr,

pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
    switch (self.target) {
        .index => |*idx| {
            var index_copy = idx.index;
            index_copy.deinit(allocator);
        },
        .name => {},
    }
    self.expr.deinit(allocator);
}
