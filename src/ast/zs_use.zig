const std = @import("std");

enum_name: []const u8,
variants: []const []const u8,
startPos: usize,
endPos: usize,

pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
    allocator.free(self.variants);
}
