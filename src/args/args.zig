const std = @import("std");

const Error = error{MissingEntryPoint};

pub const ExecutionArgs = struct { entryPoint: []const u8, dumpIr: bool = false, outputPath: ?[]const u8 = null, run: bool = false };

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
                return Error.MissingEntryPoint;
            }
        } else if (std.mem.eql(u8, arg, "-dump-ir")) {
            execArgs.dumpIr = true;
        } else if (std.mem.eql(u8, arg, "-r")) {
            execArgs.run = true;
        } else if (std.mem.eql(u8, arg, "-o")) {
            execArgs.outputPath = args.next();
        }
    }

    if (execArgs.entryPoint.len == 0) {
        return Error.MissingEntryPoint;
    }

    return execArgs;
}
