const std = @import("std");
const Tokenizer = @import("tokens/Tokenizer.zig");
const Parser = @import("Parser.zig");
const Analyzer = @import("analyze/analyzer.zig");
const Self = @This();
const IRGen = @import("ir/IRGen.zig");
const llvm = @import("codegen/LLVMCodeGen.zig");
const llvm_lib = @import("llvm");
const core = llvm_lib.core;
const engine = llvm_lib.engine;
const Args = @import("args/Args.zig");
const builtins = @import("runtime/builtins.zig");

pub fn create() Self {
    return Self{};
}

pub fn compile(self: *Self, args: Args.ExecutionArgs) !void {
    _ = self;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const file = try std.fs.cwd().openFile(args.entryPoint, .{ .mode = .read_only });
    const fileSize: usize = @intCast((try file.stat()).size);
    const buffer = try file.readToEndAlloc(allocator, fileSize);
    defer allocator.free(buffer);

    const tokenizer = Tokenizer.create(buffer);

    std.debug.print("Parsing\n", .{});
    var parser = try Parser.create(
        allocator,
        tokenizer,
        args.entryPoint,
        buffer,
    );

    const module = try parser.parse(allocator);
    defer module.deinit(allocator);

    std.debug.print("Analyzing\n", .{});

    var analyzeResult = try Analyzer.analyze(module, allocator);
    defer analyzeResult.deinit(allocator);

    for (analyzeResult.errors) |e| {
        std.debug.print("{f}\n", .{e});
    }
    if (analyzeResult.errors.len == 0) {
        std.debug.print("Generating ir\n", .{});
        const ir = try IRGen.generateIr(&module, allocator, &analyzeResult.resolutions, &analyzeResult.overloadedNames);
        defer ir.deinit(allocator);

        if (args.dumpIr or args.run) {
            std.debug.print("Generating llvm\n", .{});
            const llvmModule = try llvm.generateLLVMModule(&ir, allocator);

            if (args.dumpIr) {
                const irStr = core.LLVMPrintModuleToString(llvmModule);
                defer core.LLVMDisposeMessage(irStr);
                const irSlice = std.mem.span(irStr);
                const stdout = std.fs.File.stdout();
                try stdout.writeAll(irSlice);
                try stdout.writeAll("\n");

                if (args.dumpIrOutput) |outputPath| {
                    const outFile = try std.fs.cwd().createFile(outputPath, .{});
                    defer outFile.close();
                    try outFile.writeAll(irSlice);
                }
            }

            if (args.run) {
                std.debug.print("Running\n", .{});
                engine.LLVMLinkInMCJIT();

                var ee: llvm_lib.types.LLVMExecutionEngineRef = null;
                var err: [*c]u8 = null;
                const result = engine.LLVMCreateExecutionEngineForModule(&ee, llvmModule, &err);
                if (result != 0) {
                    if (err) |errMsg| {
                        std.debug.print("MCJIT error: {s}\n", .{errMsg});
                        core.LLVMDisposeMessage(errMsg);
                    }
                    core.LLVMDisposeModule(llvmModule);
                    return;
                }

                builtins.registerBuiltins(ee, llvmModule);

                const initFn = core.LLVMGetNamedFunction(llvmModule, "init");
                if (initFn == null) {
                    std.debug.print("Error: 'init' function not found in module\n", .{});
                    engine.LLVMDisposeExecutionEngine(ee);
                    return;
                }

                _ = engine.LLVMRunFunction(ee, initFn, 0, null);
                engine.LLVMDisposeExecutionEngine(ee);
            } else {
                core.LLVMDisposeModule(llvmModule);
            }
        }
    }
}
