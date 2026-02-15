const std = @import("std");

const Error = error{MissingEntryPoint};

const ExecutionArgs = struct { entryPoint: []const u8 };

pub fn collectArgs() Error!ExecutionArgs {
    var execArgs = ExecutionArgs{ .entryPoint = "" };
    var args = std.process.args();
    _ = args.skip();

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-i")) {
            const filePathOpt = args.next();

            if (filePathOpt) |filePath| {
                execArgs.entryPoint = filePath;
            } else {
                std.debug.print("Expected file path but got end of arguments", .{});
            }
        }
    }

    if (execArgs.entryPoint.len == 0) {
        return Error.MissingEntryPoint;
    }

    return execArgs;
}
