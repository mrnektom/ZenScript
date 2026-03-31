const std = @import("std");
const Tokenizer = @import("tokens/tokenizer.zig");
const Parser = @import("parser.zig");
const Analyzer = @import("analyzer/analyzer.zig");
const Self = @This();
const IRGen = @import("ir/ir_gen.zig");
const ir = @import("ir/zsir.zig");
const llvm = @import("codegen/llvm_codegen.zig");
const llvm_lib = @import("llvm");
const core = llvm_lib.core;
const engine = llvm_lib.engine;
const Args = @import("args/args.zig");
const zsm = @import("ast/zs_module.zig");
const type_notation = @import("ast/zs_type_notation.zig");

/// Convert an AST type notation to the string name used by codegen's mapType.
fn resolveFieldTypeName(t: type_notation.ZSType) []const u8 {
    return switch (t) {
        .reference => |ref| {
            if (std.mem.eql(u8, ref, "number") or std.mem.eql(u8, ref, "int")) return "number";
            if (std.mem.eql(u8, ref, "long")) return "long";
            if (std.mem.eql(u8, ref, "short")) return "short";
            if (std.mem.eql(u8, ref, "byte")) return "byte";
            if (std.mem.eql(u8, ref, "boolean")) return "boolean";
            if (std.mem.eql(u8, ref, "char")) return "char";
            if (std.mem.eql(u8, ref, "String")) return "String";
            if (std.mem.eql(u8, ref, "c_string")) return "c_string";
            if (std.mem.eql(u8, ref, "void")) return "void";
            return ref; // struct name — will be looked up in registry
        },
        .generic => |g| {
            if (std.mem.eql(u8, g.name, "Pointer")) return "pointer";
            return g.name; // other generic struct names
        },
        .array => "pointer", // arrays as pointers
    };
}

/// Build a map of struct name → field type name strings from analyzer struct defs.
fn buildStructFieldTypes(
    allocator: std.mem.Allocator,
    structDefs: *const std.StringHashMap(Analyzer.StructDef),
    depStructDefs: []const *const std.StringHashMap(Analyzer.StructDef),
) !std.StringHashMap([]const []const u8) {
    var result = std.StringHashMap([]const []const u8).init(allocator);
    errdefer {
        var it = result.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.value_ptr.*);
        }
        result.deinit();
    }
    // Add from deps
    for (depStructDefs) |defs| {
        var iter = defs.iterator();
        while (iter.next()) |entry| {
            if (!result.contains(entry.key_ptr.*)) {
                const sd = entry.value_ptr.*;
                const fieldTypes = try allocator.alloc([]const u8, sd.fields.len);
                errdefer allocator.free(fieldTypes);
                for (sd.fields, 0..) |field, i| {
                    fieldTypes[i] = resolveFieldTypeName(field.type);
                }
                try result.put(entry.key_ptr.*, fieldTypes);
            }
        }
    }
    // Add from main module
    var iter = structDefs.iterator();
    while (iter.next()) |entry| {
        if (!result.contains(entry.key_ptr.*)) {
            const sd = entry.value_ptr.*;
            const fieldTypes = try allocator.alloc([]const u8, sd.fields.len);
            errdefer allocator.free(fieldTypes);
            for (sd.fields, 0..) |field, i| {
                fieldTypes[i] = resolveFieldTypeName(field.type);
            }
            try result.put(entry.key_ptr.*, fieldTypes);
        }
    }
    return result;
}

const CompiledModule = struct {
    analyzeResult: Analyzer.AnalyzeResult,
    irResult: IRGen.IrGenResult,
};

pub fn create() Self {
    return Self{};
}

/// Resolve a relative import path against the importing file's directory.
fn resolvePath(allocator: std.mem.Allocator, importerPath: []const u8, relativePath: []const u8) ![]const u8 {
    const dir = std.fs.path.dirname(importerPath) orelse ".";
    return try std.fs.path.join(allocator, &.{ dir, relativePath });
}

/// Recursively compile a module and all its dependencies.
/// Returns the CompiledModule for the given path.
fn compileModule(
    allocator: std.mem.Allocator,
    path: []const u8,
    cache: *std.StringHashMap(CompiledModule),
    inProgress: *std.StringHashMap(void),
    allSources: *std.ArrayList([]const u8),
    allModules: *std.ArrayList(zsm.ZSModule),
) !CompiledModule {
    // Check cache
    if (cache.get(path)) |result| return result;

    // Cycle detection
    if (inProgress.contains(path)) {
        std.debug.print("Error: Circular import detected for '{s}'\n", .{path});
        return error.CircularImport;
    }
    try inProgress.put(path, {});

    // Read file
    const file = try std.fs.cwd().openFile(path, .{ .mode = .read_only });
    defer file.close();
    const fileSize: usize = @intCast((try file.stat()).size);
    const buffer = try file.readToEndAlloc(allocator, fileSize);
    try allSources.append(allocator, buffer);

    // Tokenize & parse
    const tokenizer = Tokenizer.create(buffer);
    var parser = try Parser.create(allocator, tokenizer, path, buffer);
    const module = try parser.parse(allocator);
    try allModules.append(allocator, module);

    // Recursively compile dependencies
    var depAnalyzeResults = std.StringHashMap(Analyzer.AnalyzeResult).init(allocator);
    defer depAnalyzeResults.deinit();

    // Build imported var names from deps for this module's IRGen
    var importedVarNames = std.StringHashMap([]const u8).init(allocator);
    defer importedVarNames.deinit();

    for (module.deps) |dep| {
        const resolvedPath = try resolvePath(allocator, path, dep.path);
        defer allocator.free(resolvedPath);

        const depPath = try allocator.dupe(u8, resolvedPath);
        defer allocator.free(depPath);
        const depCompiled = try compileModule(allocator, depPath, cache, inProgress, allSources, allModules);
        try depAnalyzeResults.put(dep.path, depCompiled.analyzeResult);

        // Map imported symbol names (using alias if present) to their IR names from the dep
        for (dep.symbols) |sym| {
            const localName = sym.alias orelse sym.name;
            if (depCompiled.irResult.varNames.get(sym.name)) |irName| {
                try importedVarNames.put(localName, irName);
            }
        }
    }

    // Analyze
    const analyzeResult = try Analyzer.analyze(module, allocator, &depAnalyzeResults);

    // Generate IR
    const irResult = try IRGen.generateIrWithImports(
        &module,
        allocator,
        &analyzeResult.resolutions,
        &analyzeResult.overloadedNames,
        &analyzeResult.fieldIndices,
        &analyzeResult.enumInits,
        &analyzeResult.derefTypes,
        &analyzeResult.indexElemTypes,
        analyzeResult.monomorphizedFunctions.items,
        &analyzeResult.structInitResolutions,
        &importedVarNames,
        &analyzeResult.monomorphizedEnums,
        &analyzeResult.matchEnumNames,
    );

    const compiled = CompiledModule{
        .analyzeResult = analyzeResult,
        .irResult = irResult,
    };

    // Cache result and unmark in-progress
    const cacheKey = try allocator.dupe(u8, path);
    errdefer allocator.free(cacheKey);
    try cache.put(cacheKey, compiled);
    _ = inProgress.remove(path);

    return cache.get(path).?;
}

/// Merge dependency IR instructions before entry module IR.
/// Dependencies' fn_def and fn_decl go first, then entry module's instructions.
fn mergeIr(
    allocator: std.mem.Allocator,
    depModules: []const CompiledModule,
    entryIr: *const ir.ZSIRInstructions,
) !ir.ZSIRInstructions {
    var merged = try std.ArrayList(ir.ZSIR).initCapacity(allocator, 32);
    defer merged.deinit(allocator);

    // Add all dependency instructions first (skip module_init — deps are already inlined)
    for (depModules) |dep| {
        for (dep.irResult.instructions.instructions) |inst| {
            if (inst == .module_init) continue;
            try merged.append(allocator, inst);
        }
    }

    // Add entry module instructions (skip module_init — deps are already inlined)
    for (entryIr.instructions) |inst| {
        if (inst == .module_init) continue;
        try merged.append(allocator, inst);
    }

    return .{ .instructions = try allocator.dupe(ir.ZSIR, merged.items) };
}

/// Find the prelude.zs path relative to the compiler executable.
fn findPreludePath(allocator: std.mem.Allocator) !?[]const u8 {
    // Try relative to executable
    var buf: [4096]u8 = undefined;
    if (std.fs.selfExePath(&buf)) |ep| {
        const exeDir = std.fs.path.dirname(ep) orelse ".";
        const candidate = try std.fs.path.join(allocator, &.{ exeDir, "stdlib", "prelude.zs" });
        if (std.fs.cwd().access(candidate, .{})) |_| {
            return candidate;
        } else |_| {
            allocator.free(candidate);
        }
        // Try one level up (zig-out/bin/../stdlib)
        const parentDir = std.fs.path.dirname(exeDir) orelse ".";
        const candidate2 = try std.fs.path.join(allocator, &.{ parentDir, "stdlib", "prelude.zs" });
        if (std.fs.cwd().access(candidate2, .{})) |_| {
            return candidate2;
        } else |_| {
            allocator.free(candidate2);
        }
    } else |_| {}

    // Try CWD
    const cwdCandidate = try allocator.dupe(u8, "stdlib/prelude.zs");
    if (std.fs.cwd().access(cwdCandidate, .{})) |_| {
        return cwdCandidate;
    } else |_| {
        allocator.free(cwdCandidate);
    }

    return null;
}

pub fn compile(self: *Self, args: Args.ExecutionArgs) !void {
    _ = self;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const file = try std.fs.cwd().openFile(args.entryPoint, .{ .mode = .read_only });
    defer file.close();
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

    // Compile dependencies recursively
    var cache = std.StringHashMap(CompiledModule).init(allocator);
    defer {
        var cacheIter = cache.iterator();
        while (cacheIter.next()) |entry| {
            entry.value_ptr.analyzeResult.deinit(allocator);
            entry.value_ptr.irResult.deinit(allocator);
            allocator.free(entry.key_ptr.*);
        }
        cache.deinit();
    }
    var inProgress = std.StringHashMap(void).init(allocator);
    defer inProgress.deinit();
    var allSources = try std.ArrayList([]const u8).initCapacity(allocator, 4);
    defer {
        for (allSources.items) |s| allocator.free(s);
        allSources.deinit(allocator);
    }
    var allModules = try std.ArrayList(zsm.ZSModule).initCapacity(allocator, 4);
    defer {
        for (allModules.items) |m| m.deinit(allocator);
        allModules.deinit(allocator);
    }

    var depAnalyzeResults = std.StringHashMap(Analyzer.AnalyzeResult).init(allocator);
    defer depAnalyzeResults.deinit();

    // Build imported var names for the entry module
    var importedVarNames = std.StringHashMap([]const u8).init(allocator);
    defer importedVarNames.deinit();

    // Collect compiled dep modules in order
    var depCompiled = try std.ArrayList(CompiledModule).initCapacity(allocator, 4);
    defer depCompiled.deinit(allocator);

    for (module.deps) |dep| {
        const resolvedPath = try resolvePath(allocator, args.entryPoint, dep.path);
        defer allocator.free(resolvedPath);

        const depPath = try allocator.dupe(u8, resolvedPath);
        defer allocator.free(depPath);
        const depResult = try compileModule(allocator, depPath, &cache, &inProgress, &allSources, &allModules);
        try depAnalyzeResults.put(dep.path, depResult.analyzeResult);
        try depCompiled.append(allocator, depResult);

        // Map imported symbol names to their IR names from the dep
        for (dep.symbols) |sym| {
            const localName = sym.alias orelse sym.name;
            if (depResult.irResult.varNames.get(sym.name)) |irName| {
                try importedVarNames.put(localName, irName);
            }
        }
    }

    // Auto-import stdlib prelude
    var preludeExports: ?*const @import("analyzer/symbol_table_stack.zig").SymbolTable = null;
    var preludeOverloads: ?*const std.StringHashMap(std.ArrayList(Analyzer.OverloadEntry)) = null;
    var preludeStructDefs: ?*const std.StringHashMap(Analyzer.StructDef) = null;
    var preludeEnumDefs: ?*const std.StringHashMap(Analyzer.EnumDef) = null;
    var preludeGenericFns: ?*const std.StringHashMap(Analyzer.GenericFnDef) = null;
    if (try findPreludePath(allocator)) |pPath| {
        defer allocator.free(pPath);
        if (compileModule(allocator, pPath, &cache, &inProgress, &allSources, &allModules)) |preludeCompiled| {
            // Add prelude first so its functions (alloc, free, etc.) are available
            try depCompiled.append(allocator, preludeCompiled);
            // Add prelude's transitive deps (like arraylist.zs) after
            var cacheIter2 = cache.iterator();
            while (cacheIter2.next()) |cEntry| {
                // Check if already in depCompiled (avoid duplicates)
                var found = false;
                for (depCompiled.items) |existing| {
                    if (existing.irResult.instructions.instructions.ptr == cEntry.value_ptr.irResult.instructions.instructions.ptr) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    try depCompiled.append(allocator, cEntry.value_ptr.*);
                }
            }
            // Get a stable pointer from the cache (not the local copy which goes out of scope)
            const cachedPrelude = cache.getPtr(pPath) orelse unreachable;
            preludeExports = &cachedPrelude.analyzeResult.exports;
            preludeOverloads = &cachedPrelude.analyzeResult.overloads;
            preludeStructDefs = &cachedPrelude.analyzeResult.exportedStructDefs;
            preludeEnumDefs = &cachedPrelude.analyzeResult.exportedEnumDefs;
            preludeGenericFns = &cachedPrelude.analyzeResult.genericFns;

            // Map all exported symbols from prelude to IR names
            var exportIter = cachedPrelude.analyzeResult.exports.iterator();
            while (exportIter.next()) |entry| {
                if (cachedPrelude.irResult.varNames.get(entry.key_ptr.*)) |irName| {
                    try importedVarNames.put(entry.key_ptr.*, irName);
                }
            }
        } else |err| {
            std.debug.print("Warning: could not compile prelude: {}\n", .{err});
        }
    }

    std.debug.print("Analyzing\n", .{});

    var analyzeResult = try Analyzer.analyzeWithPrelude(module, allocator, &depAnalyzeResults, preludeExports, preludeOverloads, preludeStructDefs, preludeEnumDefs, preludeGenericFns);
    defer analyzeResult.deinit(allocator);

    for (analyzeResult.errors) |e| {
        std.debug.print("{f}\n", .{e});
    }
    if (analyzeResult.errors.len == 0) {
        std.debug.print("Generating ir\n", .{});
        var entryIrResult = try IRGen.generateIrWithImports(
            &module,
            allocator,
            &analyzeResult.resolutions,
            &analyzeResult.overloadedNames,
            &analyzeResult.fieldIndices,
            &analyzeResult.enumInits,
            &analyzeResult.derefTypes,
            &analyzeResult.indexElemTypes,
            analyzeResult.monomorphizedFunctions.items,
            &analyzeResult.structInitResolutions,
            &importedVarNames,
            &analyzeResult.monomorphizedEnums,
            &analyzeResult.matchEnumNames,
        );
        defer entryIrResult.deinit(allocator);

        // Merge dependency IR with entry module IR
        const mergedIr = try mergeIr(allocator, depCompiled.items, &entryIrResult.instructions);
        // Only free the merged instructions array, not individual instructions (owned by deps/entry)
        defer allocator.free(mergedIr.instructions);

        if (args.dumpIr or args.run or args.outputPath != null) {
            std.debug.print("Generating llvm\n", .{});

            // Build struct field types map from all struct defs
            var depStructDefPtrs = try std.ArrayList(*const std.StringHashMap(Analyzer.StructDef)).initCapacity(allocator, depCompiled.items.len);
            defer depStructDefPtrs.deinit(allocator);
            for (depCompiled.items) |dep| {
                try depStructDefPtrs.append(allocator, &dep.analyzeResult.structDefs);
                try depStructDefPtrs.append(allocator, &dep.analyzeResult.exportedStructDefs);
            }
            var structFieldTypes = try buildStructFieldTypes(allocator, &analyzeResult.structDefs, depStructDefPtrs.items);
            defer {
                var sfIter = structFieldTypes.iterator();
                while (sfIter.next()) |entry| {
                    allocator.free(entry.value_ptr.*);
                }
                structFieldTypes.deinit();
            }

            const llvmModule = try llvm.generateLLVMModule(&mergedIr, allocator, &structFieldTypes);

            if (args.dumpIr) {
                const irStr = core.LLVMPrintModuleToString(llvmModule);
                defer core.LLVMDisposeMessage(irStr);
                const irSlice = std.mem.span(irStr);
                const stdout = std.fs.File.stdout();
                try stdout.writeAll(irSlice);
                try stdout.writeAll("\n");
            }

            if (args.outputPath) |outputPath| {
                // Compilation mode: emit object file and link
                llvm.generateMain(llvmModule);

                const tmpObjPath = "/tmp/zs_output.o";
                try llvm.emitObjectFile(llvmModule, tmpObjPath);
                core.LLVMDisposeModule(llvmModule);

                // Link with cc
                const ccResult = try std.process.Child.run(.{
                    .allocator = allocator,
                    .argv = &.{ "zig", "cc", "-o", outputPath, tmpObjPath, "-ldl" },
                });
                defer allocator.free(ccResult.stdout);
                defer allocator.free(ccResult.stderr);

                const linkFailed = switch (ccResult.term) {
                    .Exited => |code| code != 0,
                    else => true,
                };
                if (linkFailed) {
                    std.debug.print("Linker error:\n{s}\n", .{ccResult.stderr});
                    return;
                }

                // Clean up temp file
                std.fs.cwd().deleteFile(tmpObjPath) catch {};

                std.debug.print("Compiled to {s}\n", .{outputPath});
            } else if (args.run) {
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
