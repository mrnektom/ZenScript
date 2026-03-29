const std = @import("std");
const type_notation = @import("zs_type_notation.zig");
const stmt = @import("zs_stmt.zig");

name: []const u8,
type_params: []const []const u8,
fields: []ZSStructField,
modifiers: stmt.Modifiers,
startPos: usize,
endPos: usize,

pub const ZSStructField = struct {
    name: []const u8,
    type: type_notation.ZSType,
};

pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
    for (self.fields) |*field| {
        field.type.deinit(allocator);
    }
    allocator.free(self.fields);
    allocator.free(self.type_params);
}
