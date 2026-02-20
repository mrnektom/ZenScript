const std = @import("std");
const root = @import("ZenScript");
message: []const u8,
filename: []const u8,
codeLine: []const u8,
lineNumber: usize,
lineCol: usize,
start: usize,
end: usize,

pub fn format(
    self: @This(),
    writer: *std.Io.Writer,
) std.Io.Writer.Error!void {
    try writer.print("\n{s}\n{s}:{}:{}\n{} | {s}\n", .{
        self.message,
        self.filename,
        self.lineNumber + 1,
        self.lineCol + 1,
        self.lineNumber + 1,
        self.codeLine,
    });

    try writer.print("{} | ", .{self.lineNumber + 1});

    for (0..self.lineCol) |_| {
        try writer.writeByte(' ');
    }

    try writer.print("^\n", .{});
}
