const std = @import("std");
const type_notation = @import("zs_type_notation.zig");
const stmt = @import("zs_stmt.zig");

name: []const u8,
type_params: []const []const u8,
variants: []ZSEnumVariant,
modifiers: stmt.Modifiers,
startPos: usize,
endPos: usize,

pub const ZSEnumVariant = struct {
    name: []const u8,
    payload_type: ?type_notation.ZSType,
};

pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
    for (self.variants) |*variant| {
        if (variant.payload_type) |*pt| {
            pt.deinit(allocator);
        }
    }
    allocator.free(self.variants);
    allocator.free(self.type_params);
}
