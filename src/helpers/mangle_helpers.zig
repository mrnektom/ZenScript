const std = @import("std");

pub fn computeMangledName(allocator: std.mem.Allocator, name: []const u8, argTypes: []const []const u8) ![]const u8 {
    var len: usize = name.len + 2; // name + "__"
    for (argTypes, 0..) |argType, i| {
        if (i > 0) len += 1; // "_" separator
        len += argType.len;
    }

    const buf = try allocator.alloc(u8, len);
    var pos: usize = 0;
    @memcpy(buf[pos..][0..name.len], name);
    pos += name.len;
    @memcpy(buf[pos..][0..2], "__");
    pos += 2;
    for (argTypes, 0..) |argType, i| {
        if (i > 0) {
            buf[pos] = '_';
            pos += 1;
        }
        @memcpy(buf[pos..][0..argType.len], argType);
        pos += argType.len;
    }
    return buf;
}
