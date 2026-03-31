const std = @import("std");
const Expr = @import("zs_expr.zig").ZSExpr;

pub const ReassignTarget = union(enum) {
    name: []const u8,
    index: IndexTarget,
    field: FieldTarget,
};

pub const IndexTarget = struct {
    subject_name: []const u8,
    index: Expr,
    startPos: usize,
};

pub const FieldTarget = struct {
    subject: *ReassignTarget,
    field_name: []const u8,
    startPos: usize,
};

target: ReassignTarget,
expr: Expr,

pub fn deinitTarget(target: *const ReassignTarget, allocator: std.mem.Allocator) void {
    switch (target.*) {
        .index => |*idx| {
            var index_copy = idx.index;
            index_copy.deinit(allocator);
        },
        .field => |*f| {
            deinitTarget(f.subject, allocator);
            allocator.destroy(f.subject);
        },
        .name => {},
    }
}

pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
    deinitTarget(&self.target, allocator);
    self.expr.deinit(allocator);
}
