const std = @import("std");
const llvm = @import("llvm");
const target = llvm.target;
const target_machine = llvm.target_machine;
const types = llvm.types;
const core = llvm.core;
const ir = @import("../ir/zsir.zig");

const LocalVar = struct {
    ptr: types.LLVMValueRef,
    ty: types.LLVMTypeRef,
};

const LoopContext = struct {
    condBlock: types.LLVMBasicBlockRef,
    afterBlock: types.LLVMBasicBlockRef,
};

/// Module-level struct type registry, populated by generateLLVMModule pre-scan.
/// NOTE: This global mutable state is not thread-safe. If concurrent compilation
/// is ever needed, this must be refactored to pass the registry through the call chain.
var structTypeRegistry: std.StringHashMap(types.LLVMTypeRef) = undefined;
var structTypeRegistryInitialized: bool = false;

pub fn generate() void {
    _ = target.LLVMInitializeNativeTarget();
    _ = target.LLVMInitializeNativeAsmPrinter();
    _ = target.LLVMInitializeNativeAsmParser();
    defer core.LLVMShutdown();

    // Create a new LLVM module
    const module: types.LLVMModuleRef = core.LLVMModuleCreateWithName("sum_module");
    defer core.LLVMDisposeModule(module);

    var params: [2]types.LLVMTypeRef = [_]types.LLVMTypeRef{
        core.LLVMInt32Type(),
        core.LLVMInt32Type(),
    };

    // Create a function that computes the sum of two integers
    const func_type: types.LLVMTypeRef = core.LLVMFunctionType(core.LLVMInt32Type(), &params, 2, 0);
    const sum_func: types.LLVMValueRef = core.LLVMAddFunction(module, "sum", func_type);
    const entry: types.LLVMBasicBlockRef = core.LLVMAppendBasicBlock(sum_func, "entry");
    const builder: types.LLVMBuilderRef = core.LLVMCreateBuilder();
    defer core.LLVMDisposeBuilder(builder);

    core.LLVMPositionBuilderAtEnd(builder, entry);
    const arg1: types.LLVMValueRef = core.LLVMGetParam(sum_func, 0);
    const arg2: types.LLVMValueRef = core.LLVMGetParam(sum_func, 1);
    const sum: types.LLVMValueRef = core.LLVMBuildAdd(builder, arg1, arg2, "sum");
    _ = core.LLVMBuildRet(builder, sum);

    // Dump the LLVM module to stdout
    core.LLVMDumpModule(module);
}

pub fn generateLLVMModule(
    instructions: *const ir.ZSIRInstructions,
    allocator: std.mem.Allocator,
    structFieldTypes: ?*const std.StringHashMap([]const []const u8),
) !types.LLVMModuleRef {
    startupLLVM();

    // Initialize struct type registry
    structTypeRegistry = std.StringHashMap(types.LLVMTypeRef).init(allocator);
    structTypeRegistryInitialized = true;
    defer {
        structTypeRegistry.deinit();
        structTypeRegistryInitialized = false;
    }

    // Always register String
    try structTypeRegistry.put("String", getStringType());

    // Register struct types from analyzer
    if (structFieldTypes) |sft| {
        var iter = sft.iterator();
        while (iter.next()) |entry| {
            const fieldTypeNames = entry.value_ptr.*;
            const fieldLLVMTypes = try allocator.alloc(types.LLVMTypeRef, fieldTypeNames.len);
            defer allocator.free(fieldLLVMTypes);
            for (fieldTypeNames, 0..) |ft, i| {
                fieldLLVMTypes[i] = mapType(ft);
            }
            const count: c_uint = @intCast(fieldTypeNames.len);
            const structType = core.LLVMStructType(fieldLLVMTypes.ptr, count, 0);
            try structTypeRegistry.put(entry.key_ptr.*, structType);
        }
    }

    const module: types.LLVMModuleRef = core.LLVMModuleCreateWithName("zs_module");
    errdefer core.LLVMDisposeModule(module);

    // Declare dlopen(i8*, i32) -> i8*
    const ptrType = core.LLVMPointerType(core.LLVMInt8Type(), 0);
    {
        var dlopenParams: [2]types.LLVMTypeRef = .{ ptrType, core.LLVMInt32Type() };
        const dlopenType = core.LLVMFunctionType(ptrType, &dlopenParams, 2, 0);
        _ = core.LLVMAddFunction(module, "dlopen", dlopenType);
    }
    // Declare dlsym(i8*, i8*) -> i8*
    {
        var dlsymParams: [2]types.LLVMTypeRef = .{ ptrType, ptrType };
        const dlsymType = core.LLVMFunctionType(ptrType, &dlsymParams, 2, 0);
        _ = core.LLVMAddFunction(module, "dlsym", dlsymType);
    }

    var params: [0]types.LLVMTypeRef = [_]types.LLVMTypeRef{};

    const func_type: types.LLVMTypeRef = core.LLVMFunctionType(core.LLVMVoidType(), &params, 0, 0);
    const init_func: types.LLVMValueRef = core.LLVMAddFunction(module, "init", func_type);
    const entry: types.LLVMBasicBlockRef = core.LLVMAppendBasicBlock(init_func, "entry");

    const builder: types.LLVMBuilderRef = core.LLVMCreateBuilder();
    defer core.LLVMDisposeBuilder(builder);

    core.LLVMPositionBuilderAtEnd(builder, entry);

    // Pre-pass: forward-declare all functions so they can reference each other
    try forwardDeclareAll(module, instructions.instructions, allocator);

    var locals = std.StringHashMap(LocalVar).init(allocator);
    defer locals.deinit();

    for (instructions.instructions) |instruction| {
        try generateInstruction(builder, module, &locals, &instruction, allocator, null);
    }

    _ = core.LLVMBuildRet(builder, null);

    return module;
}

/// Forward-declare all functions in the IR so they can reference each other.
fn forwardDeclareAll(module: types.LLVMModuleRef, instrs: []const ir.ZSIR, allocator: std.mem.Allocator) !void {
    for (instrs) |inst| {
        switch (inst) {
            .fn_def => |def| {
                const nameZ = try allocator.dupeZ(u8, def.name);
                defer allocator.free(nameZ);
                // Skip if already declared
                if (core.LLVMGetNamedFunction(module, nameZ.ptr) != null) continue;
                const paramTypes = try allocator.alloc(types.LLVMTypeRef, def.argTypes.len);
                defer allocator.free(paramTypes);
                for (def.argTypes, 0..) |argType, i| {
                    paramTypes[i] = mapType(argType);
                }
                const paramCount: c_uint = @intCast(def.argTypes.len);
                const retType = mapType(def.retType);
                const funcType = core.LLVMFunctionType(retType, paramTypes.ptr, paramCount, 0);
                _ = core.LLVMAddFunction(module, nameZ.ptr, funcType);
            },
            .fn_decl => |decl| {
                const nameZ = try allocator.dupeZ(u8, decl.name);
                defer allocator.free(nameZ);
                if (core.LLVMGetNamedFunction(module, nameZ.ptr) != null) continue;
                const paramTypes = try allocator.alloc(types.LLVMTypeRef, decl.argTypes.len);
                defer allocator.free(paramTypes);
                for (decl.argTypes, 0..) |argType, i| {
                    paramTypes[i] = mapType(argType);
                }
                const paramCount: c_uint = @intCast(decl.argTypes.len);
                const retType = mapType(decl.retType);
                const funcType = core.LLVMFunctionType(retType, paramTypes.ptr, paramCount, 0);
                _ = core.LLVMAddFunction(module, nameZ.ptr, funcType);
            },
            else => {},
        }
    }
}

fn generateInstruction(
    builder: types.LLVMBuilderRef,
    module: types.LLVMModuleRef,
    locals: *std.StringHashMap(LocalVar),
    instruction: *const ir.ZSIR,
    allocator: std.mem.Allocator,
    loopCtx: ?LoopContext,
) std.mem.Allocator.Error!void {
    switch (instruction.*) {
        .assign => try generateAssign(builder, locals, instruction.assign),
        .store => generateStore(builder, locals, instruction.store),
        .call => try generateCall(builder, module, locals, instruction.call, allocator),
        .fn_decl => try generateFnDecl(module, instruction.fn_decl, allocator),
        .fn_def => try generateFnDef(builder, module, instruction.fn_def, allocator),
        .ret => generateRet(builder, locals, instruction.ret),
        .branch => try generateBranch(builder, module, locals, instruction.branch, allocator, loopCtx),
        .compare => try generateCompare(builder, locals, instruction.compare, allocator),
        .arith => try generateArith(builder, locals, instruction.arith, allocator),
        .loop => try generateLoop(builder, module, locals, instruction.loop, allocator, loopCtx),
        .module_init => try generateModuleInit(builder, module, instruction.module_init, allocator),
        .array_init => try generateArrayInit(builder, locals, instruction.array_init),
        .index_access => try generateIndexAccess(builder, locals, instruction.index_access),
        .index_store => generateIndexStore(builder, locals, instruction.index_store),
        .struct_init => try generateStructInit(builder, locals, instruction.struct_init, allocator),
        .field_access => try generateFieldAccess(builder, locals, instruction.field_access),
        .ptr_op => try generatePtrOp(builder, locals, instruction.ptr_op),
        .deref_op => try generateDerefOp(builder, locals, instruction.deref_op),
        .enum_decl => try generateEnumDeclCodegen(module, instruction.enum_decl, allocator),
        .enum_init => try generateEnumInitCodegen(builder, module, locals, instruction.enum_init, allocator),
        .match_expr => try generateMatchCodegen(builder, module, locals, instruction.match_expr, allocator, loopCtx),
        .break_stmt => {
            if (loopCtx) |ctx| {
                _ = core.LLVMBuildBr(builder, ctx.afterBlock);
            }
        },
        .continue_stmt => {
            if (loopCtx) |ctx| {
                _ = core.LLVMBuildBr(builder, ctx.condBlock);
            }
        },
        .not_op => try generateNot(builder, locals, instruction.not_op),
    }
}

fn generateFnDecl(module: types.LLVMModuleRef, decl: ir.ZSIRFnDecl, allocator: std.mem.Allocator) !void {
    const paramCount: c_uint = @intCast(decl.argTypes.len);
    const paramTypes = try allocator.alloc(types.LLVMTypeRef, decl.argTypes.len);
    defer allocator.free(paramTypes);
    for (decl.argTypes, 0..) |argType, i| {
        paramTypes[i] = mapType(argType);
    }

    const retType = mapType(decl.retType);
    const funcType = core.LLVMFunctionType(retType, paramTypes.ptr, paramCount, 0);
    const nameZ = try allocator.dupeZ(u8, decl.name);
    defer allocator.free(nameZ);

    // Skip if already declared/defined (from forward declaration pass or duplicate dep)
    if (core.LLVMGetNamedFunction(module, nameZ.ptr) != null) return;

    if (!decl.external) {
        // Non-external declaration: just add function declaration
        _ = core.LLVMAddFunction(module, nameZ.ptr, funcType);
        return;
    }

    // External function: generate a wrapper with lazy dlsym resolution
    const ptrType = core.LLVMPointerType(core.LLVMInt8Type(), 0);

    // 1. Global variable for cached function pointer: @<name>_ptr = global ptr null
    const ptrVarNameSlice = try std.fmt.allocPrint(allocator, "{s}_ptr", .{decl.name});
    defer allocator.free(ptrVarNameSlice);
    const ptrVarName = try allocator.dupeZ(u8, ptrVarNameSlice);
    defer allocator.free(ptrVarName);
    const globalPtr = core.LLVMAddGlobal(module, ptrType, ptrVarName.ptr);
    core.LLVMSetInitializer(globalPtr, core.LLVMConstNull(ptrType));

    // 2. Global string constant with the function name: @.str.<name> = private constant [N x i8] c"<name>\00"
    const strConstNameSlice = try std.fmt.allocPrint(allocator, ".str.{s}", .{decl.name});
    defer allocator.free(strConstNameSlice);
    const strConstName = try allocator.dupeZ(u8, strConstNameSlice);
    defer allocator.free(strConstName);
    const nameLen: c_uint = @intCast(decl.name.len);
    const nameConst = core.LLVMConstString(nameZ.ptr, nameLen, 0); // 0 = add null terminator
    const strGlobal = core.LLVMAddGlobal(module, core.LLVMTypeOf(nameConst), strConstName.ptr);
    core.LLVMSetInitializer(strGlobal, nameConst);
    core.LLVMSetGlobalConstant(strGlobal, 1);
    core.LLVMSetLinkage(strGlobal, .LLVMPrivateLinkage);

    // 3. Generate wrapper function
    const wrapperFunc = core.LLVMAddFunction(module, nameZ.ptr, funcType);
    const entryBlock = core.LLVMAppendBasicBlock(wrapperFunc, "entry");
    const resolveBlock = core.LLVMAppendBasicBlock(wrapperFunc, "resolve");
    const callBlock = core.LLVMAppendBasicBlock(wrapperFunc, "call");

    const builder = core.LLVMCreateBuilder();
    defer core.LLVMDisposeBuilder(builder);

    // entry: load cached pointer, check if null, branch
    core.LLVMPositionBuilderAtEnd(builder, entryBlock);
    const cachedPtr = core.LLVMBuildLoad2(builder, ptrType, globalPtr, "ptr");
    const isNull = core.LLVMBuildICmp(builder, .LLVMIntEQ, cachedPtr, core.LLVMConstNull(ptrType), "is_null");
    _ = core.LLVMBuildCondBr(builder, isNull, resolveBlock, callBlock);

    // resolve: call dlsym(NULL, "<name>"), store result, branch to call
    core.LLVMPositionBuilderAtEnd(builder, resolveBlock);
    const dlsymFunc = core.LLVMGetNamedFunction(module, "dlsym") orelse unreachable; // declared in generateLLVMModule
    var dlsymArgs: [2]types.LLVMValueRef = .{
        core.LLVMConstNull(ptrType), // RTLD_DEFAULT = NULL
        strGlobal,
    };
    const dlsymFuncType = core.LLVMGlobalGetValueType(dlsymFunc);
    const sym = core.LLVMBuildCall2(builder, dlsymFuncType, dlsymFunc, &dlsymArgs, 2, "sym");
    _ = core.LLVMBuildStore(builder, sym, globalPtr);
    _ = core.LLVMBuildBr(builder, callBlock);

    // call: load function pointer, call it with forwarded args, return result
    core.LLVMPositionBuilderAtEnd(builder, callBlock);
    const fptr = core.LLVMBuildLoad2(builder, ptrType, globalPtr, "fptr");

    const callArgs = try allocator.alloc(types.LLVMValueRef, paramCount);
    defer allocator.free(callArgs);
    var i: c_uint = 0;
    while (i < paramCount) : (i += 1) {
        callArgs[i] = core.LLVMGetParam(wrapperFunc, i);
    }

    const isVoid = core.LLVMGetTypeKind(retType) == .LLVMVoidTypeKind;
    const resultName: [*:0]const u8 = if (isVoid) "" else "result";
    const callResult = core.LLVMBuildCall2(builder, funcType, fptr, callArgs.ptr, paramCount, resultName);

    if (isVoid) {
        _ = core.LLVMBuildRetVoid(builder);
    } else {
        _ = core.LLVMBuildRet(builder, callResult);
    }
}

fn generateFnDef(
    outerBuilder: types.LLVMBuilderRef,
    module: types.LLVMModuleRef,
    def: ir.ZSIRFnDef,
    allocator: std.mem.Allocator,
) !void {
    const paramCount: c_uint = @intCast(def.argTypes.len);
    const paramTypes = try allocator.alloc(types.LLVMTypeRef, def.argTypes.len);
    defer allocator.free(paramTypes);
    for (def.argTypes, 0..) |argType, i| {
        paramTypes[i] = mapType(argType);
    }

    const retType = mapType(def.retType);
    const funcType = core.LLVMFunctionType(retType, paramTypes.ptr, paramCount, 0);
    const nameZ = try allocator.dupeZ(u8, def.name);
    defer allocator.free(nameZ);
    // Use existing forward-declared function or create new one
    const func = core.LLVMGetNamedFunction(module, nameZ.ptr) orelse core.LLVMAddFunction(module, nameZ.ptr, funcType);

    // Skip if function already has a body (from a duplicate dep)
    if (core.LLVMCountBasicBlocks(func) > 0) return;

    const entry = core.LLVMAppendBasicBlock(func, "entry");
    const builder = core.LLVMCreateBuilder();
    defer core.LLVMDisposeBuilder(builder);
    core.LLVMPositionBuilderAtEnd(builder, entry);

    // Alloca and store params
    var fnLocals = std.StringHashMap(LocalVar).init(allocator);
    defer fnLocals.deinit();

    for (def.argNames, 0..) |argName, i| {
        const argNameZ = try allocator.dupeZ(u8, argName);
        defer allocator.free(argNameZ);
        const paramType = paramTypes[i];
        const alloca = core.LLVMBuildAlloca(builder, paramType, argNameZ.ptr);
        _ = core.LLVMBuildStore(builder, core.LLVMGetParam(func, @intCast(i)), alloca);
        try fnLocals.put(argName, LocalVar{ .ptr = alloca, .ty = paramType });
    }

    // Generate body instructions
    for (def.body) |inst| {
        try generateInstruction(builder, module, &fnLocals, &inst, allocator, null);
    }

    // Add implicit return void if the function returns void and last instruction isn't a terminator
    const currentBlock = core.LLVMGetInsertBlock(builder);
    const terminator = core.LLVMGetBasicBlockTerminator(currentBlock);
    if (terminator == null) {
        if (core.LLVMGetTypeKind(retType) == .LLVMVoidTypeKind) {
            _ = core.LLVMBuildRetVoid(builder);
        } else {
            // Return a default zero value
            _ = core.LLVMBuildRet(builder, core.LLVMConstInt(retType, 0, 0));
        }
    }

    // Restore the outer builder position (it was pointing at init's entry block)
    _ = outerBuilder;
}

fn generateRet(
    builder: types.LLVMBuilderRef,
    locals: *std.StringHashMap(LocalVar),
    ret: ir.ZSIRRet,
) void {
    if (ret.value) |valName| {
        if (locals.get(valName)) |local| {
            const val = core.LLVMBuildLoad2(builder, local.ty, local.ptr, "retval");
            _ = core.LLVMBuildRet(builder, val);
        } else {
            _ = core.LLVMBuildRetVoid(builder);
        }
    } else {
        _ = core.LLVMBuildRetVoid(builder);
    }
}

fn generateBranch(
    builder: types.LLVMBuilderRef,
    module: types.LLVMModuleRef,
    locals: *std.StringHashMap(LocalVar),
    branch: ir.ZSIRBranch,
    allocator: std.mem.Allocator,
    loopCtx: ?LoopContext,
) !void {
    // Load the condition value
    var condVal: types.LLVMValueRef = undefined;
    if (locals.get(branch.condition)) |local| {
        condVal = core.LLVMBuildLoad2(builder, local.ty, local.ptr, "cond");
    } else {
        // Condition should always be in locals
        return;
    }

    // Convert to i1 (condition != 0)
    const condBool = core.LLVMBuildICmp(
        builder,
        .LLVMIntNE,
        condVal,
        core.LLVMConstInt(core.LLVMTypeOf(condVal), 0, 0),
        "condbool",
    );

    const currentFunc = core.LLVMGetBasicBlockParent(core.LLVMGetInsertBlock(builder));
    const thenBlock = core.LLVMAppendBasicBlock(currentFunc, "then");
    const elseBlock = core.LLVMAppendBasicBlock(currentFunc, "else");
    const mergeBlock = core.LLVMAppendBasicBlock(currentFunc, "merge");

    _ = core.LLVMBuildCondBr(builder, condBool, thenBlock, elseBlock);

    // Then block
    core.LLVMPositionBuilderAtEnd(builder, thenBlock);
    for (branch.thenBody) |inst| {
        try generateInstruction(builder, module, locals, &inst, allocator, loopCtx);
    }
    // Remember the then-block terminator state and result local
    const thenTerm = core.LLVMGetBasicBlockTerminator(core.LLVMGetInsertBlock(builder));
    const thenResultLocal: ?LocalVar = if (branch.thenResult) |n| locals.get(n) else null;
    if (thenTerm == null) {
        _ = core.LLVMBuildBr(builder, mergeBlock);
    }

    // Else block
    core.LLVMPositionBuilderAtEnd(builder, elseBlock);
    for (branch.elseBody) |inst| {
        try generateInstruction(builder, module, locals, &inst, allocator, loopCtx);
    }
    const elseTerm = core.LLVMGetBasicBlockTerminator(core.LLVMGetInsertBlock(builder));
    const elseResultLocal: ?LocalVar = if (branch.elseResult) |n| locals.get(n) else null;
    if (elseTerm == null) {
        _ = core.LLVMBuildBr(builder, mergeBlock);
    }

    // Merge block
    core.LLVMPositionBuilderAtEnd(builder, mergeBlock);

    // If this branch produces a value, determine the type from whichever branch provided a result
    if (branch.resultName) |resName| {
        const resultTy: types.LLVMTypeRef = if (thenResultLocal) |l| l.ty else if (elseResultLocal) |l| l.ty else null;
        if (resultTy) |ty| {
            const resultPtr = core.LLVMBuildAlloca(builder, ty, "ifres");
            // Store from then-branch: go back, insert store before the terminator
            if (thenTerm == null) {
                if (thenResultLocal) |local| {
                    // Insert before then-block's terminator (the br we added)
                    const thenBr = core.LLVMGetBasicBlockTerminator(thenBlock);
                    core.LLVMPositionBuilderBefore(builder, thenBr);
                    const val = core.LLVMBuildLoad2(builder, local.ty, local.ptr, "thenval");
                    _ = core.LLVMBuildStore(builder, val, resultPtr);
                }
            }
            // Store from else-branch: go back, insert store before the terminator
            if (elseTerm == null) {
                if (elseResultLocal) |local| {
                    const elseBr = core.LLVMGetBasicBlockTerminator(elseBlock);
                    core.LLVMPositionBuilderBefore(builder, elseBr);
                    const val = core.LLVMBuildLoad2(builder, local.ty, local.ptr, "elseval");
                    _ = core.LLVMBuildStore(builder, val, resultPtr);
                }
            }
            // Reposition builder at merge block
            core.LLVMPositionBuilderAtEnd(builder, mergeBlock);
            try locals.put(resName, LocalVar{ .ptr = resultPtr, .ty = ty });
        }
    }
}

fn generateCompare(
    builder: types.LLVMBuilderRef,
    locals: *std.StringHashMap(LocalVar),
    cmp: ir.ZSIRCompare,
    allocator: std.mem.Allocator,
) !void {
    _ = allocator;

    // Load LHS
    var lhsVal: types.LLVMValueRef = undefined;
    var lhsWidth: c_uint = 32;
    if (locals.get(cmp.lhs)) |local| {
        lhsVal = core.LLVMBuildLoad2(builder, local.ty, local.ptr, "lhs");
        if (core.LLVMGetTypeKind(local.ty) == .LLVMIntegerTypeKind) {
            lhsWidth = core.LLVMGetIntTypeWidth(local.ty);
        }
    } else {
        return;
    }

    // Load RHS
    var rhsVal: types.LLVMValueRef = undefined;
    var rhsWidth: c_uint = 32;
    if (locals.get(cmp.rhs)) |local| {
        rhsVal = core.LLVMBuildLoad2(builder, local.ty, local.ptr, "rhs");
        if (core.LLVMGetTypeKind(local.ty) == .LLVMIntegerTypeKind) {
            rhsWidth = core.LLVMGetIntTypeWidth(local.ty);
        }
    } else {
        return;
    }

    // Widen narrower operand to match the wider one
    const widerWidth = @max(lhsWidth, rhsWidth);
    if (lhsWidth < widerWidth) {
        lhsVal = core.LLVMBuildSExt(builder, lhsVal, core.LLVMIntType(widerWidth), "cmplhsext");
    }
    if (rhsWidth < widerWidth) {
        rhsVal = core.LLVMBuildSExt(builder, rhsVal, core.LLVMIntType(widerWidth), "cmprhsext");
    }

    const pred: types.LLVMIntPredicate = if (std.mem.eql(u8, cmp.op, "=="))
        .LLVMIntEQ
    else if (std.mem.eql(u8, cmp.op, "!="))
        .LLVMIntNE
    else if (std.mem.eql(u8, cmp.op, ">"))
        .LLVMIntSGT
    else if (std.mem.eql(u8, cmp.op, "<"))
        .LLVMIntSLT
    else if (std.mem.eql(u8, cmp.op, ">="))
        .LLVMIntSGE
    else
        .LLVMIntSLE;

    const cmpResult = core.LLVMBuildICmp(builder, pred, lhsVal, rhsVal, "cmp");

    // Store result as i1 (boolean)
    const ptr = core.LLVMBuildAlloca(builder, core.LLVMInt1Type(), "cmpres");
    _ = core.LLVMBuildStore(builder, cmpResult, ptr);
    try locals.put(cmp.resultName, LocalVar{ .ptr = ptr, .ty = core.LLVMInt1Type() });
}

fn generateArith(
    builder: types.LLVMBuilderRef,
    locals: *std.StringHashMap(LocalVar),
    arithInst: ir.ZSIRArith,
    allocator: std.mem.Allocator,
) !void {
    _ = allocator;

    var lhsVal: types.LLVMValueRef = undefined;
    var lhsWidth: c_uint = 32;
    if (locals.get(arithInst.lhs)) |local| {
        lhsVal = core.LLVMBuildLoad2(builder, local.ty, local.ptr, "lhs");
        if (core.LLVMGetTypeKind(local.ty) == .LLVMIntegerTypeKind) {
            lhsWidth = core.LLVMGetIntTypeWidth(local.ty);
        }
    } else {
        return;
    }

    var rhsVal: types.LLVMValueRef = undefined;
    var rhsWidth: c_uint = 32;
    if (locals.get(arithInst.rhs)) |local| {
        rhsVal = core.LLVMBuildLoad2(builder, local.ty, local.ptr, "rhs");
        if (core.LLVMGetTypeKind(local.ty) == .LLVMIntegerTypeKind) {
            rhsWidth = core.LLVMGetIntTypeWidth(local.ty);
        }
    } else {
        return;
    }

    // Widen narrower operand to match the wider one
    const resultWidth = @max(lhsWidth, rhsWidth);
    const resultTy = core.LLVMIntType(resultWidth);
    if (lhsWidth < resultWidth) {
        lhsVal = core.LLVMBuildSExt(builder, lhsVal, resultTy, "lhsext");
    }
    if (rhsWidth < resultWidth) {
        rhsVal = core.LLVMBuildSExt(builder, rhsVal, resultTy, "rhsext");
    }

    const result = if (std.mem.eql(u8, arithInst.op, "+"))
        core.LLVMBuildAdd(builder, lhsVal, rhsVal, "add")
    else if (std.mem.eql(u8, arithInst.op, "-"))
        core.LLVMBuildSub(builder, lhsVal, rhsVal, "sub")
    else if (std.mem.eql(u8, arithInst.op, "*"))
        core.LLVMBuildMul(builder, lhsVal, rhsVal, "mul")
    else if (std.mem.eql(u8, arithInst.op, "/"))
        core.LLVMBuildSDiv(builder, lhsVal, rhsVal, "div")
    else
        core.LLVMBuildSRem(builder, lhsVal, rhsVal, "rem");

    const ptr = core.LLVMBuildAlloca(builder, resultTy, "arithres");
    _ = core.LLVMBuildStore(builder, result, ptr);
    try locals.put(arithInst.resultName, LocalVar{ .ptr = ptr, .ty = resultTy });
}

fn generateLoop(
    builder: types.LLVMBuilderRef,
    module: types.LLVMModuleRef,
    locals: *std.StringHashMap(LocalVar),
    loop: ir.ZSIRLoop,
    allocator: std.mem.Allocator,
    _: ?LoopContext,
) !void {
    const currentFunc = core.LLVMGetBasicBlockParent(core.LLVMGetInsertBlock(builder));
    const condBlock = core.LLVMAppendBasicBlock(currentFunc, "while.cond");
    const bodyBlock = core.LLVMAppendBasicBlock(currentFunc, "while.body");
    const afterBlock = core.LLVMAppendBasicBlock(currentFunc, "while.after");

    // For for-loops with a step, create a step block; continue jumps there
    // For while-loops, continue jumps directly to condBlock
    const hasStep = loop.step != null and loop.step.?.len > 0;
    const stepBlock = if (hasStep) core.LLVMAppendBasicBlock(currentFunc, "for.step") else null;
    const continueTarget = if (stepBlock) |sb| sb else condBlock;

    const innerLoopCtx = LoopContext{ .condBlock = continueTarget, .afterBlock = afterBlock };

    // Branch to condition block
    _ = core.LLVMBuildBr(builder, condBlock);

    // Condition block: evaluate condition
    core.LLVMPositionBuilderAtEnd(builder, condBlock);
    for (loop.condition) |inst| {
        try generateInstruction(builder, module, locals, &inst, allocator, innerLoopCtx);
    }

    // Load condition and compare != 0
    var condVal: types.LLVMValueRef = undefined;
    if (locals.get(loop.conditionName)) |local| {
        condVal = core.LLVMBuildLoad2(builder, local.ty, local.ptr, "whilecond");
    } else {
        _ = core.LLVMBuildBr(builder, afterBlock);
        core.LLVMPositionBuilderAtEnd(builder, bodyBlock);
        _ = core.LLVMBuildBr(builder, condBlock);
        core.LLVMPositionBuilderAtEnd(builder, afterBlock);
        return;
    }

    const condBool = core.LLVMBuildICmp(
        builder,
        .LLVMIntNE,
        condVal,
        core.LLVMConstInt(core.LLVMTypeOf(condVal), 0, 0),
        "whilebool",
    );
    _ = core.LLVMBuildCondBr(builder, condBool, bodyBlock, afterBlock);

    // Body block
    core.LLVMPositionBuilderAtEnd(builder, bodyBlock);
    for (loop.body) |inst| {
        try generateInstruction(builder, module, locals, &inst, allocator, innerLoopCtx);
    }
    // Check if body has a terminator (e.g., return, break, continue), if not fall through
    const bodyTerm = core.LLVMGetBasicBlockTerminator(core.LLVMGetInsertBlock(builder));
    if (bodyTerm == null) {
        _ = core.LLVMBuildBr(builder, continueTarget);
    }

    // Step block (for for-loops)
    if (stepBlock) |sb| {
        core.LLVMPositionBuilderAtEnd(builder, sb);
        if (loop.step) |step| {
            for (step) |inst| {
                try generateInstruction(builder, module, locals, &inst, allocator, innerLoopCtx);
            }
        }
        _ = core.LLVMBuildBr(builder, condBlock);
    }

    // Continue after loop
    core.LLVMPositionBuilderAtEnd(builder, afterBlock);
}

fn generateModuleInit(
    builder: types.LLVMBuilderRef,
    module: types.LLVMModuleRef,
    modInit: ir.ZSIRModuleInit,
    allocator: std.mem.Allocator,
) !void {
    // Call the dependency's init function: <module_path>_init()
    const initName = try std.fmt.allocPrint(allocator, "{s}_init", .{modInit.name});
    defer allocator.free(initName);
    const initNameZ = try allocator.dupeZ(u8, initName);
    defer allocator.free(initNameZ);

    var initFunc = core.LLVMGetNamedFunction(module, initNameZ.ptr);
    if (initFunc == null) {
        // Declare it as external void()
        var noParams: [0]types.LLVMTypeRef = .{};
        const funcType = core.LLVMFunctionType(core.LLVMVoidType(), &noParams, 0, 0);
        initFunc = core.LLVMAddFunction(module, initNameZ.ptr, funcType);
    }

    const funcType = core.LLVMGlobalGetValueType(initFunc);
    var noArgs: [0]types.LLVMValueRef = .{};
    _ = core.LLVMBuildCall2(builder, funcType, initFunc, &noArgs, 0, "");
}

fn generateAssign(builder: types.LLVMBuilderRef, locals: *std.StringHashMap(LocalVar), assign: ir.ZSIRAssign) !void {
    const ty = switch (assign.value) {
        .number => core.LLVMInt32Type(),
        .string => getStringType(),
        .boolean => core.LLVMInt1Type(),
        .char => core.LLVMInt8Type(),
    };

    const value = try getValue(builder, &assign.value);

    const ptr: types.LLVMValueRef = core.LLVMBuildAlloca(
        builder,
        ty,
        "x",
    );

    _ = core.LLVMBuildStore(builder, value, ptr);

    try locals.put(assign.varName, LocalVar{ .ptr = ptr, .ty = ty });
}

fn generateStore(
    builder: types.LLVMBuilderRef,
    locals: *std.StringHashMap(LocalVar),
    storeInst: ir.ZSIRStore,
) void {
    const targetLocal = locals.get(storeInst.target) orelse return;
    const valueLocal = locals.get(storeInst.value) orelse return;
    var val = core.LLVMBuildLoad2(builder, valueLocal.ty, valueLocal.ptr, "storeval");

    // Coerce value type to match target type
    const targetKind = core.LLVMGetTypeKind(targetLocal.ty);
    const valueKind = core.LLVMGetTypeKind(valueLocal.ty);
    if (targetKind == .LLVMIntegerTypeKind and valueKind == .LLVMIntegerTypeKind) {
        const tw = core.LLVMGetIntTypeWidth(targetLocal.ty);
        const vw = core.LLVMGetIntTypeWidth(valueLocal.ty);
        if (vw < tw) {
            val = core.LLVMBuildSExt(builder, val, targetLocal.ty, "storeext");
        } else if (vw > tw) {
            val = core.LLVMBuildTrunc(builder, val, targetLocal.ty, "storetrunc");
        }
    }

    _ = core.LLVMBuildStore(builder, val, targetLocal.ptr);
}

fn generateCall(
    builder: types.LLVMBuilderRef,
    module: types.LLVMModuleRef,
    locals: *std.StringHashMap(LocalVar),
    call: ir.ZSIRCall,
    allocator: std.mem.Allocator,
) !void {
    // Special handling for load_library: call dlopen
    if (std.mem.eql(u8, call.fnName, "load_library")) {
        if (call.argNames.len > 0) {
            if (locals.get(call.argNames[0])) |local| {
                // local is a ZSString struct {i32, i64}; extract len and data fields
                const strStruct = core.LLVMBuildLoad2(builder, local.ty, local.ptr, "str");
                const strLen = core.LLVMBuildExtractValue(builder, strStruct, 0, "strlen");
                const strData = core.LLVMBuildExtractValue(builder, strStruct, 1, "strdata");
                // Convert i64 back to pointer for memcpy
                const strPtr = core.LLVMBuildIntToPtr(builder, strData, core.LLVMPointerType(core.LLVMInt8Type(), 0), "strptr");

                // dlopen needs a null-terminated string; allocate len+1 bytes, copy, add \0
                const i8Type = core.LLVMInt8Type();
                const one = core.LLVMConstInt(core.LLVMInt32Type(), 1, 0);
                const bufLen = core.LLVMBuildAdd(builder, strLen, one, "buflen");
                const buf = core.LLVMBuildArrayAlloca(builder, i8Type, bufLen, "cstr");

                // memcpy the string data
                const memcpyFn = blk: {
                    var existing = core.LLVMGetNamedFunction(module, "llvm.memcpy.p0.p0.i32");
                    if (existing == null) {
                        var memcpyParams: [4]types.LLVMTypeRef = .{
                            core.LLVMPointerType(i8Type, 0),
                            core.LLVMPointerType(i8Type, 0),
                            core.LLVMInt32Type(),
                            core.LLVMInt1Type(),
                        };
                        const memcpyType = core.LLVMFunctionType(core.LLVMVoidType(), &memcpyParams, 4, 0);
                        existing = core.LLVMAddFunction(module, "llvm.memcpy.p0.p0.i32", memcpyType);
                    }
                    break :blk existing;
                };
                const memcpyFnType = core.LLVMGlobalGetValueType(memcpyFn);
                var memcpyArgs: [4]types.LLVMValueRef = .{
                    buf,
                    strPtr,
                    strLen,
                    core.LLVMConstInt(core.LLVMInt1Type(), 0, 0), // isvolatile = false
                };
                _ = core.LLVMBuildCall2(builder, memcpyFnType, memcpyFn, &memcpyArgs, 4, "");

                // Write null terminator at buf[len]
                const nullPos = core.LLVMBuildGEP2(builder, i8Type, buf, @constCast(&[_]types.LLVMValueRef{strLen}), 1, "nullpos");
                _ = core.LLVMBuildStore(builder, core.LLVMConstInt(i8Type, 0, 0), nullPos);

                const dlopenFunc = core.LLVMGetNamedFunction(module, "dlopen") orelse unreachable; // declared in generateLLVMModule
                const dlopenFuncType = core.LLVMGlobalGetValueType(dlopenFunc);
                // 258 = RTLD_NOW (2) | RTLD_GLOBAL (256) on Linux
                var dlopenArgs: [2]types.LLVMValueRef = .{
                    buf,
                    core.LLVMConstInt(core.LLVMInt32Type(), 258, 0),
                };
                _ = core.LLVMBuildCall2(builder, dlopenFuncType, dlopenFunc, &dlopenArgs, 2, "");
            }
        }
        return;
    }

    // Handle intrinsics
    if (std.mem.eql(u8, call.fnName, "__syscall2")) {
        try generateSyscall2(builder, locals, call);
        return;
    }
    if (std.mem.eql(u8, call.fnName, "__syscall3")) {
        try generateSyscall3(builder, locals, call);
        return;
    }
    if (std.mem.eql(u8, call.fnName, "__syscall6")) {
        try generateSyscall6(builder, locals, call);
        return;
    }
    const fnNameZ = try allocator.dupeZ(u8, call.fnName);
    defer allocator.free(fnNameZ);
    const funcRef = core.LLVMGetNamedFunction(module, fnNameZ.ptr);
    if (funcRef == null) return;

    const funcType = core.LLVMGlobalGetValueType(funcRef);

    const args = try allocator.alloc(types.LLVMValueRef, call.argNames.len);
    defer allocator.free(args);
    for (call.argNames, 0..) |argName, i| {
        if (locals.get(argName)) |local| {
            args[i] = core.LLVMBuildLoad2(builder, local.ty, local.ptr, "arg");
        } else {
            std.debug.print("warning: generateCall: missing local '{s}' for argument {d} of '{s}'\n", .{ argName, i, call.fnName });
            return;
        }
    }

    const argCount: c_uint = @intCast(call.argNames.len);

    const retType = core.LLVMGetReturnType(funcType);
    const isVoid = core.LLVMGetTypeKind(retType) == .LLVMVoidTypeKind;
    const resultName: [*:0]const u8 = if (isVoid) "" else "call_result";

    const result = core.LLVMBuildCall2(builder, funcType, funcRef, args.ptr, argCount, resultName);

    // Store non-void results so they can be referenced later
    if (!isVoid) {
        const ptr = core.LLVMBuildAlloca(builder, retType, "callres");
        _ = core.LLVMBuildStore(builder, result, ptr);
        try locals.put(call.resultName, LocalVar{ .ptr = ptr, .ty = retType });
    }
}

// --- Intrinsics ---

fn generateSyscall3(
    builder: types.LLVMBuilderRef,
    locals: *std.StringHashMap(LocalVar),
    call: ir.ZSIRCall,
) !void {
    if (call.argNames.len != 4) return;

    const i64Type = core.LLVMInt64Type();
    const i32Type = core.LLVMInt32Type();

    // Load all 4 args (nr, a1, a2, a3) and extend to i64
    var args64: [4]types.LLVMValueRef = undefined;
    for (call.argNames, 0..) |argName, i| {
        if (locals.get(argName)) |local| {
            const val = core.LLVMBuildLoad2(builder, local.ty, local.ptr, "sarg");
            // If already i64 (e.g. from __ptr_to_int), use directly; otherwise sext
            if (core.LLVMGetTypeKind(local.ty) == .LLVMIntegerTypeKind and
                core.LLVMGetIntTypeWidth(local.ty) == 64)
            {
                args64[i] = val;
            } else {
                args64[i] = core.LLVMBuildSExt(builder, val, i64Type, "sext");
            }
        } else {
            return;
        }
    }

    // Build inline asm for syscall
    // Inputs: rax=nr, rdi=a1, rsi=a2, rdx=a3
    // Output: rax
    var paramTypes: [4]types.LLVMTypeRef = .{ i64Type, i64Type, i64Type, i64Type };
    const asmFnType = core.LLVMFunctionType(i64Type, &paramTypes, 4, 0);
    const inlineAsm = core.LLVMGetInlineAsm(
        asmFnType,
        @constCast("syscall"),
        7,
        @constCast("={rax},{rax},{rdi},{rsi},{rdx},~{rcx},~{r11},~{memory}"),
        56,
        1, // hasSideEffects
        0, // isAlignStack
        .LVMInlineAsmDialectATT,
        0, // canThrow
    );

    const result64 = core.LLVMBuildCall2(builder, asmFnType, inlineAsm, &args64, 4, "syscall");

    // Truncate result to i32
    const result32 = core.LLVMBuildTrunc(builder, result64, i32Type, "systrunc");
    const ptr = core.LLVMBuildAlloca(builder, i32Type, "sysres");
    _ = core.LLVMBuildStore(builder, result32, ptr);
    try locals.put(call.resultName, LocalVar{ .ptr = ptr, .ty = i32Type });
}

fn generateSyscall2(
    builder: types.LLVMBuilderRef,
    locals: *std.StringHashMap(LocalVar),
    call: ir.ZSIRCall,
) !void {
    if (call.argNames.len != 3) return;

    const i64Type = core.LLVMInt64Type();

    var args64: [3]types.LLVMValueRef = undefined;
    for (call.argNames, 0..) |argName, i| {
        if (locals.get(argName)) |local| {
            const val = core.LLVMBuildLoad2(builder, local.ty, local.ptr, "sarg");
            if (core.LLVMGetTypeKind(local.ty) == .LLVMIntegerTypeKind and
                core.LLVMGetIntTypeWidth(local.ty) == 64)
            {
                args64[i] = val;
            } else {
                args64[i] = core.LLVMBuildSExt(builder, val, i64Type, "sext");
            }
        } else {
            return;
        }
    }

    var paramTypes: [3]types.LLVMTypeRef = .{ i64Type, i64Type, i64Type };
    const asmFnType = core.LLVMFunctionType(i64Type, &paramTypes, 3, 0);
    const constraint = "={rax},{rax},{rdi},{rsi},~{rcx},~{r11},~{memory}";
    const inlineAsm = core.LLVMGetInlineAsm(
        asmFnType,
        @constCast("syscall"),
        7,
        @constCast(constraint),
        constraint.len,
        1,
        0,
        .LVMInlineAsmDialectATT,
        0,
    );

    const result64 = core.LLVMBuildCall2(builder, asmFnType, inlineAsm, &args64, 3, "syscall");

    const ptr = core.LLVMBuildAlloca(builder, i64Type, "sysres");
    _ = core.LLVMBuildStore(builder, result64, ptr);
    try locals.put(call.resultName, LocalVar{ .ptr = ptr, .ty = i64Type });
}

fn generateSyscall6(
    builder: types.LLVMBuilderRef,
    locals: *std.StringHashMap(LocalVar),
    call: ir.ZSIRCall,
) !void {
    if (call.argNames.len != 7) return;

    const i64Type = core.LLVMInt64Type();

    var args64: [7]types.LLVMValueRef = undefined;
    for (call.argNames, 0..) |argName, i| {
        if (locals.get(argName)) |local| {
            const val = core.LLVMBuildLoad2(builder, local.ty, local.ptr, "sarg");
            if (core.LLVMGetTypeKind(local.ty) == .LLVMIntegerTypeKind and
                core.LLVMGetIntTypeWidth(local.ty) == 64)
            {
                args64[i] = val;
            } else {
                args64[i] = core.LLVMBuildSExt(builder, val, i64Type, "sext");
            }
        } else {
            return;
        }
    }

    var paramTypes: [7]types.LLVMTypeRef = .{ i64Type, i64Type, i64Type, i64Type, i64Type, i64Type, i64Type };
    const asmFnType = core.LLVMFunctionType(i64Type, &paramTypes, 7, 0);
    const constraint = "={rax},{rax},{rdi},{rsi},{rdx},{r10},{r8},{r9},~{rcx},~{r11},~{memory}";
    const inlineAsm = core.LLVMGetInlineAsm(
        asmFnType,
        @constCast("syscall"),
        7,
        @constCast(constraint),
        constraint.len,
        1,
        0,
        .LVMInlineAsmDialectATT,
        0,
    );

    const result64 = core.LLVMBuildCall2(builder, asmFnType, inlineAsm, &args64, 7, "syscall");

    const ptr = core.LLVMBuildAlloca(builder, i64Type, "sysres");
    _ = core.LLVMBuildStore(builder, result64, ptr);
    try locals.put(call.resultName, LocalVar{ .ptr = ptr, .ty = i64Type });
}

fn generateStructInit(
    builder: types.LLVMBuilderRef,
    locals: *std.StringHashMap(LocalVar),
    si: ir.ZSIRStructInit,
    allocator: std.mem.Allocator,
) !void {
    // Try to use registered struct type (ensures consistent field ordering)
    const registeredType: ?types.LLVMTypeRef = if (structTypeRegistryInitialized) structTypeRegistry.get(si.structName) else null;

    if (registeredType) |structType| {
        // Use registered type — field indices come from the struct definition order.
        // The struct_init fields may be in any order; we need to map them to definition indices.
        // Since we don't have field name→index mapping here, the struct_init fields must match
        // definition order. Build the struct value at the field positions provided by the IR.
        var structVal = core.LLVMGetUndef(structType);
        for (si.fields, 0..) |field, i| {
            const local = locals.get(field.value) orelse return;
            var val = core.LLVMBuildLoad2(builder, local.ty, local.ptr, "fieldval");
            const expectedType = core.LLVMStructGetTypeAtIndex(structType, @intCast(i));
            // Auto-convert if types differ (e.g. i32 vs i64)
            if (local.ty != expectedType) {
                const localKind = core.LLVMGetTypeKind(local.ty);
                const expectedKind = core.LLVMGetTypeKind(expectedType);
                if (localKind == .LLVMIntegerTypeKind and expectedKind == .LLVMIntegerTypeKind) {
                    const localWidth = core.LLVMGetIntTypeWidth(local.ty);
                    const expectedWidth = core.LLVMGetIntTypeWidth(expectedType);
                    if (localWidth < expectedWidth) {
                        val = core.LLVMBuildSExt(builder, val, expectedType, "sext");
                    } else if (localWidth > expectedWidth) {
                        val = core.LLVMBuildTrunc(builder, val, expectedType, "trunc");
                    }
                }
            }
            structVal = core.LLVMBuildInsertValue(builder, structVal, val, @intCast(i), "withfield");
        }
        const ptr = core.LLVMBuildAlloca(builder, structType, "structinit");
        _ = core.LLVMBuildStore(builder, structVal, ptr);
        try locals.put(si.resultName, LocalVar{ .ptr = ptr, .ty = structType });
    } else {
        // Fallback: build struct type from field values
        const fieldTypes = try allocator.alloc(types.LLVMTypeRef, si.fields.len);
        defer allocator.free(fieldTypes);
        for (si.fields, 0..) |field, i| {
            const local = locals.get(field.value) orelse return;
            fieldTypes[i] = local.ty;
        }
        const count: c_uint = @intCast(si.fields.len);
        const structType = core.LLVMStructType(fieldTypes.ptr, count, 0);

        var structVal = core.LLVMGetUndef(structType);
        for (si.fields, 0..) |field, i| {
            const local = locals.get(field.value) orelse return;
            const val = core.LLVMBuildLoad2(builder, local.ty, local.ptr, "fieldval");
            structVal = core.LLVMBuildInsertValue(builder, structVal, val, @intCast(i), "withfield");
        }

        const ptr = core.LLVMBuildAlloca(builder, structType, "structinit");
        _ = core.LLVMBuildStore(builder, structVal, ptr);
        try locals.put(si.resultName, LocalVar{ .ptr = ptr, .ty = structType });
    }
}

fn generateFieldAccess(
    builder: types.LLVMBuilderRef,
    locals: *std.StringHashMap(LocalVar),
    fa: ir.ZSIRFieldAccess,
) !void {
    const local = locals.get(fa.subject) orelse return;
    const typeKind = core.LLVMGetTypeKind(local.ty);

    if (typeKind == .LLVMStructTypeKind) {
        // Struct field access: load struct, extractvalue at fieldIndex
        const structVal = core.LLVMBuildLoad2(builder, local.ty, local.ptr, "structval");
        const extracted = core.LLVMBuildExtractValue(builder, structVal, fa.fieldIndex, "field");
        const resultTy = core.LLVMTypeOf(extracted);
        const ptr = core.LLVMBuildAlloca(builder, resultTy, "fieldres");
        _ = core.LLVMBuildStore(builder, extracted, ptr);
        try locals.put(fa.resultName, LocalVar{ .ptr = ptr, .ty = resultTy });
    } else if (typeKind == .LLVMArrayTypeKind) {
        // Array .length pseudo-field
        const length = core.LLVMGetArrayLength(local.ty);
        const lengthVal = core.LLVMConstInt(core.LLVMInt32Type(), length, 0);
        const ptr = core.LLVMBuildAlloca(builder, core.LLVMInt32Type(), "arrlen");
        _ = core.LLVMBuildStore(builder, lengthVal, ptr);
        try locals.put(fa.resultName, LocalVar{ .ptr = ptr, .ty = core.LLVMInt32Type() });
    }
}

fn generatePtrOp(
    builder: types.LLVMBuilderRef,
    locals: *std.StringHashMap(LocalVar),
    op: ir.ZSIRPtrOp,
) !void {
    const operand = locals.get(op.operand) orelse return;
    const i64Type = core.LLVMInt64Type();

    var rawPtr: types.LLVMValueRef = undefined;

    if (core.LLVMGetTypeKind(operand.ty) == .LLVMArrayTypeKind) {
        // Array: GEP to get pointer to first element
        var indices: [2]types.LLVMValueRef = .{
            core.LLVMConstInt(core.LLVMInt32Type(), 0, 0),
            core.LLVMConstInt(core.LLVMInt32Type(), 0, 0),
        };
        rawPtr = core.LLVMBuildGEP2(builder, operand.ty, operand.ptr, &indices, 2, "arrptr");
    } else {
        // Scalar: the alloca itself is already a pointer
        rawPtr = operand.ptr;
    }

    // Convert pointer to i64
    const ptrInt = core.LLVMBuildPtrToInt(builder, rawPtr, i64Type, "ptrint");
    const alloca = core.LLVMBuildAlloca(builder, i64Type, "ptrop");
    _ = core.LLVMBuildStore(builder, ptrInt, alloca);
    try locals.put(op.resultName, LocalVar{ .ptr = alloca, .ty = i64Type });
}

fn generateDerefOp(
    builder: types.LLVMBuilderRef,
    locals: *std.StringHashMap(LocalVar),
    op: ir.ZSIRDerefOp,
) !void {
    const operand = locals.get(op.operand) orelse return;
    const i64Type = core.LLVMInt64Type();
    const pointeeType = mapType(op.pointeeType);

    // Load the i64 pointer value from the operand
    const ptrInt = core.LLVMBuildLoad2(builder, i64Type, operand.ptr, "deref_ptrint");

    // Convert i64 to a typed pointer
    const typedPtr = core.LLVMBuildIntToPtr(
        builder,
        ptrInt,
        core.LLVMPointerType(pointeeType, 0),
        "deref_ptr",
    );

    // Load the value through the pointer
    const loadedVal = core.LLVMBuildLoad2(builder, pointeeType, typedPtr, "deref_val");

    // Store the result in an alloca
    const alloca = core.LLVMBuildAlloca(builder, pointeeType, "deref_result");
    _ = core.LLVMBuildStore(builder, loadedVal, alloca);
    try locals.put(op.resultName, LocalVar{ .ptr = alloca, .ty = pointeeType });
}

fn generateNot(
    builder: types.LLVMBuilderRef,
    locals: *std.StringHashMap(LocalVar),
    op: ir.ZSIRNot,
) !void {
    const operand = locals.get(op.operand) orelse return;
    const val = core.LLVMBuildLoad2(builder, operand.ty, operand.ptr, "notval");

    // Compare operand == 0 to invert boolean
    const result = core.LLVMBuildICmp(
        builder,
        .LLVMIntEQ,
        val,
        core.LLVMConstInt(core.LLVMTypeOf(val), 0, 0),
        "not",
    );
    const i1Type = core.LLVMInt1Type();
    const ptr = core.LLVMBuildAlloca(builder, i1Type, "notres");
    _ = core.LLVMBuildStore(builder, result, ptr);
    try locals.put(op.resultName, LocalVar{ .ptr = ptr, .ty = i1Type });
}

fn generateArrayInit(
    builder: types.LLVMBuilderRef,
    locals: *std.StringHashMap(LocalVar),
    arrayInit: ir.ZSIRArrayInit,
) !void {
    const elemType = mapType(arrayInit.elementType);
    const count: c_uint = @intCast(arrayInit.elements.len);
    const arrType = core.LLVMArrayType(elemType, count);
    const arrPtr = core.LLVMBuildAlloca(builder, arrType, "arr");

    // Store each element via GEP
    for (arrayInit.elements, 0..) |elemName, i| {
        if (locals.get(elemName)) |local| {
            const val = core.LLVMBuildLoad2(builder, local.ty, local.ptr, "elem");
            var indices: [2]types.LLVMValueRef = .{
                core.LLVMConstInt(core.LLVMInt32Type(), 0, 0),
                core.LLVMConstInt(core.LLVMInt32Type(), @intCast(i), 0),
            };
            const gep = core.LLVMBuildGEP2(builder, arrType, arrPtr, &indices, 2, "gep");
            _ = core.LLVMBuildStore(builder, val, gep);
        }
    }

    try locals.put(arrayInit.resultName, LocalVar{ .ptr = arrPtr, .ty = arrType });
}

fn generateIndexAccess(
    builder: types.LLVMBuilderRef,
    locals: *std.StringHashMap(LocalVar),
    ia: ir.ZSIRIndexAccess,
) !void {
    const subjectLocal = locals.get(ia.subject) orelse return;
    const indexLocal = locals.get(ia.index) orelse return;

    const indexVal = core.LLVMBuildLoad2(builder, indexLocal.ty, indexLocal.ptr, "idx");

    // Check if subject is an i64 (pointer/long) — use pointer arithmetic instead of GEP
    const i64Type = core.LLVMInt64Type();
    if (subjectLocal.ty == i64Type) {
        const addr = core.LLVMBuildLoad2(builder, i64Type, subjectLocal.ptr, "addr");
        const idx64 = core.LLVMBuildSExt(builder, indexVal, i64Type, "idx64");

        // Stride-aware: if elemType is set, use typed element size
        if (ia.elemType) |et| {
            const llvmElemType = mapType(et);
            const elemSize: u64 = getTypeSizeBytes(llvmElemType);
            const offset = core.LLVMBuildMul(builder, idx64, core.LLVMConstInt(i64Type, elemSize, 0), "offset");
            const sum = core.LLVMBuildAdd(builder, addr, offset, "ptradd");
            const typedPtrType = core.LLVMPointerType(llvmElemType, 0);
            const typedPtr = core.LLVMBuildIntToPtr(builder, sum, typedPtrType, "typedptr");
            const val = core.LLVMBuildLoad2(builder, llvmElemType, typedPtr, "typedval");
            const resPtr = core.LLVMBuildAlloca(builder, llvmElemType, "idxres");
            _ = core.LLVMBuildStore(builder, val, resPtr);
            try locals.put(ia.resultName, LocalVar{ .ptr = resPtr, .ty = llvmElemType });
            return;
        }

        // Fallback: byte-level access for raw long subjects
        const sum = core.LLVMBuildAdd(builder, addr, idx64, "ptradd");
        const i8PtrType = core.LLVMPointerType(core.LLVMInt8Type(), 0);
        const rawPtr = core.LLVMBuildIntToPtr(builder, sum, i8PtrType, "rawptr");
        const i8Type = core.LLVMInt8Type();
        const val = core.LLVMBuildLoad2(builder, i8Type, rawPtr, "byteval");
        const resPtr = core.LLVMBuildAlloca(builder, i8Type, "idxres");
        _ = core.LLVMBuildStore(builder, val, resPtr);
        try locals.put(ia.resultName, LocalVar{ .ptr = resPtr, .ty = i8Type });
        return;
    }

    const arrType = subjectLocal.ty;
    const elemType = core.LLVMGetElementType(arrType);

    var indices: [2]types.LLVMValueRef = .{
        core.LLVMConstInt(core.LLVMInt32Type(), 0, 0),
        indexVal,
    };
    const gep = core.LLVMBuildGEP2(builder, arrType, subjectLocal.ptr, &indices, 2, "idxgep");
    const val = core.LLVMBuildLoad2(builder, elemType, gep, "idxval");

    const resPtr = core.LLVMBuildAlloca(builder, elemType, "idxres");
    _ = core.LLVMBuildStore(builder, val, resPtr);
    try locals.put(ia.resultName, LocalVar{ .ptr = resPtr, .ty = elemType });
}

fn generateIndexStore(
    builder: types.LLVMBuilderRef,
    locals: *std.StringHashMap(LocalVar),
    istor: ir.ZSIRIndexStore,
) void {
    const subjectLocal = locals.get(istor.subject) orelse return;
    const indexLocal = locals.get(istor.index) orelse return;
    const valueLocal = locals.get(istor.value) orelse return;

    const indexVal = core.LLVMBuildLoad2(builder, indexLocal.ty, indexLocal.ptr, "stidx");

    // Check if subject is an i64 (pointer/long) — use pointer arithmetic instead of GEP
    const i64Type = core.LLVMInt64Type();
    if (subjectLocal.ty == i64Type) {
        const addr = core.LLVMBuildLoad2(builder, i64Type, subjectLocal.ptr, "addr");
        const idx64 = core.LLVMBuildSExt(builder, indexVal, i64Type, "idx64");

        // Stride-aware: if elemType is set, use typed element size
        if (istor.elemType) |et| {
            const llvmElemType = mapType(et);
            const elemSize: u64 = getTypeSizeBytes(llvmElemType);
            const offset = core.LLVMBuildMul(builder, idx64, core.LLVMConstInt(i64Type, elemSize, 0), "offset");
            const sum = core.LLVMBuildAdd(builder, addr, offset, "ptradd");
            const typedPtrType = core.LLVMPointerType(llvmElemType, 0);
            const typedPtr = core.LLVMBuildIntToPtr(builder, sum, typedPtrType, "typedptr");
            var val = core.LLVMBuildLoad2(builder, valueLocal.ty, valueLocal.ptr, "stval");
            // Auto-trunc/ext if value width doesn't match element width
            if (core.LLVMGetTypeKind(valueLocal.ty) == .LLVMIntegerTypeKind and
                core.LLVMGetTypeKind(llvmElemType) == .LLVMIntegerTypeKind)
            {
                const valWidth = core.LLVMGetIntTypeWidth(valueLocal.ty);
                const elemWidth = core.LLVMGetIntTypeWidth(llvmElemType);
                if (valWidth > elemWidth) {
                    val = core.LLVMBuildTrunc(builder, val, llvmElemType, "sttrunc");
                } else if (valWidth < elemWidth) {
                    val = core.LLVMBuildSExt(builder, val, llvmElemType, "stext");
                }
            }
            _ = core.LLVMBuildStore(builder, val, typedPtr);
            return;
        }

        // Fallback: byte-level access for raw long subjects
        const sum = core.LLVMBuildAdd(builder, addr, idx64, "ptradd");
        const i8PtrType = core.LLVMPointerType(core.LLVMInt8Type(), 0);
        const rawPtr = core.LLVMBuildIntToPtr(builder, sum, i8PtrType, "rawptr");
        var val = core.LLVMBuildLoad2(builder, valueLocal.ty, valueLocal.ptr, "stval");
        const i8Type = core.LLVMInt8Type();
        // Auto-trunc if value is wider than i8
        if (core.LLVMGetTypeKind(valueLocal.ty) == .LLVMIntegerTypeKind) {
            const valWidth = core.LLVMGetIntTypeWidth(valueLocal.ty);
            if (valWidth > 8) {
                val = core.LLVMBuildTrunc(builder, val, i8Type, "sttrunc");
            }
        }
        _ = core.LLVMBuildStore(builder, val, rawPtr);
        return;
    }

    const arrType = subjectLocal.ty;
    const elemType = core.LLVMGetElementType(arrType);

    var indices: [2]types.LLVMValueRef = .{
        core.LLVMConstInt(core.LLVMInt32Type(), 0, 0),
        indexVal,
    };
    const gep = core.LLVMBuildGEP2(builder, arrType, subjectLocal.ptr, &indices, 2, "stgep");
    var val = core.LLVMBuildLoad2(builder, valueLocal.ty, valueLocal.ptr, "stval");

    // Auto-trunc if value is wider than element type (e.g. i32 -> i8 for char arrays)
    if (core.LLVMGetTypeKind(valueLocal.ty) == .LLVMIntegerTypeKind and
        core.LLVMGetTypeKind(elemType) == .LLVMIntegerTypeKind)
    {
        const valWidth = core.LLVMGetIntTypeWidth(valueLocal.ty);
        const elemWidth = core.LLVMGetIntTypeWidth(elemType);
        if (valWidth > elemWidth) {
            val = core.LLVMBuildTrunc(builder, val, elemType, "sttrunc");
        }
    }

    _ = core.LLVMBuildStore(builder, val, gep);
}

fn generateEnumDeclCodegen(
    module: types.LLVMModuleRef,
    decl: ir.ZSIREnumDecl,
    allocator: std.mem.Allocator,
) !void {
    _ = module;

    // Find the max-size payload type to determine the enum struct layout: { i32_tag, payload }
    // This supports heterogeneous payloads (e.g., Result<number, String>)
    var maxPayloadSize: u64 = 0;
    var payloadType: ?types.LLVMTypeRef = null;
    for (decl.variants) |v| {
        if (v.payloadType) |pt| {
            const llvmType = mapType(pt);
            const size = getTypeSizeBytes(llvmType);
            if (size > maxPayloadSize) {
                maxPayloadSize = size;
                payloadType = llvmType;
            }
        }
    }

    // Create a named struct type: { i32, <payload_type> }
    const nameZ = try allocator.dupeZ(u8, decl.name);
    defer allocator.free(nameZ);
    const structType = core.LLVMStructCreateNamed(core.LLVMGetGlobalContext(), nameZ.ptr);

    if (payloadType) |pt| {
        var elemTypes: [2]types.LLVMTypeRef = .{ core.LLVMInt32Type(), pt };
        core.LLVMStructSetBody(structType, &elemTypes, 2, 0);
    } else {
        // Enum with no payloads — just a tag
        var elemTypes: [1]types.LLVMTypeRef = .{core.LLVMInt32Type()};
        core.LLVMStructSetBody(structType, &elemTypes, 1, 0);
    }

    // Register in struct type registry so mapType can find it
    if (structTypeRegistryInitialized) {
        try structTypeRegistry.put(decl.name, structType);
    }
}

fn generateEnumInitCodegen(
    builder: types.LLVMBuilderRef,
    module: types.LLVMModuleRef,
    locals: *std.StringHashMap(LocalVar),
    ei: ir.ZSIREnumInit,
    allocator: std.mem.Allocator,
) !void {
    _ = module;
    const nameZ = try allocator.dupeZ(u8, ei.enumName);
    defer allocator.free(nameZ);

    // Look up the named struct type
    var enumType = core.LLVMGetTypeByName2(core.LLVMGetGlobalContext(), nameZ.ptr);
    if (enumType == null) {
        // Fallback: create an anonymous type { i32, i64 }
        var elemTypes: [2]types.LLVMTypeRef = .{ core.LLVMInt32Type(), core.LLVMInt64Type() };
        enumType = core.LLVMStructType(&elemTypes, 2, 0);
    }

    // Build the enum value
    var enumVal = core.LLVMGetUndef(enumType.?);
    // Set tag
    enumVal = core.LLVMBuildInsertValue(builder, enumVal, core.LLVMConstInt(core.LLVMInt32Type(), @intCast(ei.variantTag), 0), 0, "withtag");

    // Set payload if present
    if (ei.payload) |payloadName| {
        if (locals.get(payloadName)) |payloadLocal| {
            const payloadVal = core.LLVMBuildLoad2(builder, payloadLocal.ty, payloadLocal.ptr, "payload");
            // May need to cast payload to the expected type (union slot type)
            const expectedType = core.LLVMStructGetTypeAtIndex(enumType.?, 1);
            const expectedKind = core.LLVMGetTypeKind(expectedType);
            const actualKind = core.LLVMGetTypeKind(payloadLocal.ty);

            var castVal = payloadVal;
            if (expectedKind == .LLVMIntegerTypeKind and actualKind == .LLVMIntegerTypeKind) {
                const expectedWidth = core.LLVMGetIntTypeWidth(expectedType);
                const actualWidth = core.LLVMGetIntTypeWidth(payloadLocal.ty);
                if (actualWidth < expectedWidth) {
                    castVal = core.LLVMBuildSExt(builder, payloadVal, expectedType, "payext");
                } else if (actualWidth > expectedWidth) {
                    castVal = core.LLVMBuildTrunc(builder, payloadVal, expectedType, "paytrunc");
                }
            } else if (payloadLocal.ty != expectedType) {
                // Heterogeneous types (e.g., struct payload into larger int slot):
                // use alloca+bitcast pattern
                const payloadPtr = core.LLVMBuildAlloca(builder, payloadLocal.ty, "pay_tmp");
                _ = core.LLVMBuildStore(builder, payloadVal, payloadPtr);
                const expectedPtrType = core.LLVMPointerType(expectedType, 0);
                const castPtr = core.LLVMBuildBitCast(builder, payloadPtr, expectedPtrType, "pay_cast");
                castVal = core.LLVMBuildLoad2(builder, expectedType, castPtr, "pay_reint");
            }
            enumVal = core.LLVMBuildInsertValue(builder, enumVal, castVal, 1, "withpayload");
        }
    }

    // Store the enum value
    const ptr = core.LLVMBuildAlloca(builder, enumType.?, "enuminit");
    _ = core.LLVMBuildStore(builder, enumVal, ptr);
    try locals.put(ei.resultName, LocalVar{ .ptr = ptr, .ty = enumType.? });
}

fn generateMatchCodegen(
    builder: types.LLVMBuilderRef,
    module: types.LLVMModuleRef,
    locals: *std.StringHashMap(LocalVar),
    me: ir.ZSIRMatch,
    allocator: std.mem.Allocator,
    loopCtx: ?LoopContext,
) !void {
    const subjectLocal = locals.get(me.subject) orelse return;
    const subjectVal = core.LLVMBuildLoad2(builder, subjectLocal.ty, subjectLocal.ptr, "matchsub");

    // Extract the tag
    const tag = core.LLVMBuildExtractValue(builder, subjectVal, 0, "tag");

    // Get the current function for creating basic blocks
    const currentBlock = core.LLVMGetInsertBlock(builder);
    const func = core.LLVMGetBasicBlockParent(currentBlock);

    // Create blocks for each arm and a merge block
    const mergeBlock = core.LLVMAppendBasicBlock(func, "match_end");
    const defaultBlock = core.LLVMAppendBasicBlock(func, "match_default");

    // Position default block: unreachable (match is exhaustive)
    core.LLVMPositionBuilderAtEnd(builder, defaultBlock);
    _ = core.LLVMBuildUnreachable(builder);

    // Build switch instruction
    core.LLVMPositionBuilderAtEnd(builder, currentBlock);
    const switchInst = core.LLVMBuildSwitch(builder, tag, defaultBlock, @intCast(me.arms.len));

    // Track results from each arm for the phi node
    const armResultsBuf = try allocator.alloc(types.LLVMValueRef, me.arms.len);
    defer allocator.free(armResultsBuf);
    const armBlocksBuf = try allocator.alloc(types.LLVMBasicBlockRef, me.arms.len);
    defer allocator.free(armBlocksBuf);
    const armResults = armResultsBuf;
    const armBlocks = armBlocksBuf;
    var armCount: u32 = 0;
    var resultType: types.LLVMTypeRef = core.LLVMInt32Type(); // default

    for (me.arms) |arm| {
        const armNameZ = try std.fmt.allocPrint(allocator, "arm_{}\x00", .{arm.variantTag});
        defer allocator.free(armNameZ);
        const armBlock = core.LLVMAppendBasicBlock(func, @ptrCast(armNameZ.ptr));

        // Add case to switch
        core.LLVMAddCase(switchInst, core.LLVMConstInt(core.LLVMInt32Type(), @intCast(arm.variantTag), 0), armBlock);

        // Generate arm body
        core.LLVMPositionBuilderAtEnd(builder, armBlock);

        // If there's a binding, extract the payload and store it under the binding IR name
        if (arm.binding) |bindingName| {
            const numFields = core.LLVMCountStructElementTypes(subjectLocal.ty);
            if (numFields > 1) {
                const payload = core.LLVMBuildExtractValue(builder, subjectVal, 1, "arm_payload");
                const slotType = core.LLVMTypeOf(payload);

                // Determine the target type for this variant's payload
                const targetType: types.LLVMTypeRef = if (arm.bindingType) |bt| mapType(bt) else slotType;

                if (targetType != slotType) {
                    // Heterogeneous payload: use alloca+bitcast pattern
                    const slotPtr = core.LLVMBuildAlloca(builder, slotType, "slot_ptr");
                    _ = core.LLVMBuildStore(builder, payload, slotPtr);
                    const targetPtrType = core.LLVMPointerType(targetType, 0);
                    const castPtr = core.LLVMBuildBitCast(builder, slotPtr, targetPtrType, "cast_ptr");
                    const castVal = core.LLVMBuildLoad2(builder, targetType, castPtr, "cast_val");
                    const payloadPtr = core.LLVMBuildAlloca(builder, targetType, "binding_ptr");
                    _ = core.LLVMBuildStore(builder, castVal, payloadPtr);
                    try locals.put(bindingName, LocalVar{ .ptr = payloadPtr, .ty = targetType });
                } else {
                    const payloadPtr = core.LLVMBuildAlloca(builder, slotType, "binding_ptr");
                    _ = core.LLVMBuildStore(builder, payload, payloadPtr);
                    try locals.put(bindingName, LocalVar{ .ptr = payloadPtr, .ty = slotType });
                }
            }
        }

        // Execute arm body instructions
        for (arm.body) |bodyInst| {
            try generateInstruction(builder, module, locals, &bodyInst, allocator, loopCtx);
        }

        // Only emit branch + phi entry if the block has no terminator yet
        const armTerm = core.LLVMGetBasicBlockTerminator(core.LLVMGetInsertBlock(builder));
        if (armTerm == null) {
            // Get arm result
            if (arm.resultName) |resultName| {
                if (locals.get(resultName)) |resultLocal| {
                    const resultVal = core.LLVMBuildLoad2(builder, resultLocal.ty, resultLocal.ptr, "armresult");
                    armResults[armCount] = resultVal;
                    armBlocks[armCount] = core.LLVMGetInsertBlock(builder);
                    resultType = resultLocal.ty;
                    armCount += 1;
                }
            }

            _ = core.LLVMBuildBr(builder, mergeBlock);
        }
    }

    // Position at merge block and create phi
    core.LLVMPositionBuilderAtEnd(builder, mergeBlock);

    if (armCount == 0) {
        // All arms had terminators (return/break) — merge block is unreachable
        _ = core.LLVMBuildUnreachable(builder);
    } else if (me.resultName) |resultName| {
        const phi = core.LLVMBuildPhi(builder, resultType, "matchresult");
        core.LLVMAddIncoming(phi, armResults.ptr, armBlocks.ptr, armCount);

        const resultPtr = core.LLVMBuildAlloca(builder, resultType, "matchres");
        _ = core.LLVMBuildStore(builder, phi, resultPtr);
        try locals.put(resultName, LocalVar{ .ptr = resultPtr, .ty = resultType });
    }
}

/// Returns the size in bytes of an LLVM type. Safe to call on any sized type
/// (integers, structs, pointers, etc.) unlike LLVMGetIntTypeWidth which is
/// only valid for integer types.
fn getTypeSizeBytes(ty: types.LLVMTypeRef) u64 {
    const kind = core.LLVMGetTypeKind(ty);
    if (kind == .LLVMIntegerTypeKind) {
        const width = core.LLVMGetIntTypeWidth(ty);
        return if (width > 0) (width + 7) / 8 else 1;
    }
    // For struct/pointer/other types, use LLVMStoreSizeOfType via a temporary target data.
    // As a simpler approach, match known types by kind.
    if (kind == .LLVMPointerTypeKind) return 8; // pointers are 64-bit
    if (kind == .LLVMStructTypeKind) {
        // Sum field sizes (approximation without padding — good enough for packed-style access)
        const fieldCount = core.LLVMCountStructElementTypes(ty);
        var total: u64 = 0;
        var i: c_uint = 0;
        while (i < fieldCount) : (i += 1) {
            total += getTypeSizeBytes(core.LLVMStructGetTypeAtIndex(ty, i));
        }
        return if (total > 0) total else 1;
    }
    return 1;
}

fn mapType(name: []const u8) types.LLVMTypeRef {
    if (std.mem.eql(u8, name, "number") or std.mem.eql(u8, name, "int")) {
        return core.LLVMInt32Type();
    } else if (std.mem.eql(u8, name, "long")) {
        return core.LLVMInt64Type();
    } else if (std.mem.eql(u8, name, "short")) {
        return core.LLVMInt16Type();
    } else if (std.mem.eql(u8, name, "byte")) {
        return core.LLVMInt8Type();
    } else if (std.mem.eql(u8, name, "char")) {
        return core.LLVMInt8Type();
    } else if (std.mem.eql(u8, name, "boolean")) {
        return core.LLVMInt1Type();
    } else if (std.mem.eql(u8, name, "String")) {
        return getStringType();
    } else if (std.mem.eql(u8, name, "c_string")) {
        return core.LLVMPointerType(core.LLVMInt8Type(), 0);
    } else if (std.mem.eql(u8, name, "pointer")) {
        return core.LLVMInt64Type();
    } else if (std.mem.eql(u8, name, "void")) {
        return core.LLVMVoidType();
    } else {
        // Check struct type registry
        if (structTypeRegistryInitialized) {
            if (structTypeRegistry.get(name)) |structType| {
                return structType;
            }
        }
        // Unknown type — use opaque pointer as placeholder
        return core.LLVMPointerType(core.LLVMInt8Type(), 0);
    }
}

fn getStringType() types.LLVMTypeRef {
    var elems: [2]types.LLVMTypeRef = [_]types.LLVMTypeRef{ core.LLVMInt32Type(), core.LLVMInt64Type() };
    return core.LLVMStructType(&elems, 2, 0);
}

fn getValue(builder: types.LLVMBuilderRef, value: *const ir.ZSIRValue) !types.LLVMValueRef {
    return switch (value.*) {
        .number => core.LLVMConstInt(core.LLVMInt32Type(), @bitCast(@as(i64, value.number)), 1),
        .string => getStringValue(builder, value.string),
        .boolean => core.LLVMConstInt(core.LLVMInt1Type(), if (value.boolean) 1 else 0, 0),
        .char => core.LLVMConstInt(core.LLVMInt8Type(), @intCast(value.char), 0),
    };
}

fn getStringValue(builder: types.LLVMBuilderRef, value: [*:0]const u8) !types.LLVMValueRef {
    const zStr: []const u8 = std.mem.span(value);
    const arrTy = core.LLVMArrayType(core.LLVMInt8Type(), @intCast(zStr.len));
    const ptr = core.LLVMBuildAlloca(builder, arrTy, "strVal");
    const str = core.LLVMConstString(value, @intCast(zStr.len), 1);
    _ = core.LLVMBuildStore(builder, str, ptr);
    // Convert pointer to i64 for the { i32, i64 } string struct
    const ptrInt = core.LLVMBuildPtrToInt(builder, ptr, core.LLVMInt64Type(), "strptrint");
    const strType = getStringType();
    var strVal = core.LLVMGetUndef(strType);
    strVal = core.LLVMBuildInsertValue(builder, strVal, core.LLVMConstInt(core.LLVMInt32Type(), zStr.len, 0), 0, "withlen");
    strVal = core.LLVMBuildInsertValue(builder, strVal, ptrInt, 1, "withdata");
    return strVal;
}

fn convertToCString(allocator: std.mem.Allocator, str: *const []const u8) ![*:0]const u8 {
    return try allocator.dupeZ(u8, str.*);
}

/// Generate a main(i32, i8**) -> i32 function that calls init() and returns 0.
pub fn generateMain(module: types.LLVMModuleRef) void {
    const ptrType = core.LLVMPointerType(core.LLVMInt8Type(), 0);
    const ptrPtrType = core.LLVMPointerType(ptrType, 0);
    var mainParams: [2]types.LLVMTypeRef = .{ core.LLVMInt32Type(), ptrPtrType };
    const mainFuncType = core.LLVMFunctionType(core.LLVMInt32Type(), &mainParams, 2, 0);
    const mainFunc = core.LLVMAddFunction(module, "main", mainFuncType);

    const entry = core.LLVMAppendBasicBlock(mainFunc, "entry");
    const builder = core.LLVMCreateBuilder();
    defer core.LLVMDisposeBuilder(builder);
    core.LLVMPositionBuilderAtEnd(builder, entry);

    // Call init()
    const initFunc = core.LLVMGetNamedFunction(module, "init");
    if (initFunc != null) {
        const initFuncType = core.LLVMGlobalGetValueType(initFunc);
        var noArgs: [0]types.LLVMValueRef = .{};
        _ = core.LLVMBuildCall2(builder, initFuncType, initFunc, &noArgs, 0, "");
    }

    // return 0
    _ = core.LLVMBuildRet(builder, core.LLVMConstInt(core.LLVMInt32Type(), 0, 0));
}

/// Emit an object file from the LLVM module.
pub fn emitObjectFile(module: types.LLVMModuleRef, path: [*:0]const u8) !void {
    const triple = target_machine.LLVMGetDefaultTargetTriple();
    defer core.LLVMDisposeMessage(triple);

    var tgt: types.LLVMTargetRef = null;
    var err: [*c]u8 = null;
    if (target_machine.LLVMGetTargetFromTriple(triple, &tgt, &err) != 0) {
        if (err) |errMsg| {
            std.debug.print("Failed to get target: {s}\n", .{errMsg});
            core.LLVMDisposeMessage(errMsg);
        }
        return error.LLVMTargetError;
    }

    core.LLVMSetTarget(module, triple);

    const machine = target_machine.LLVMCreateTargetMachine(
        tgt,
        triple,
        "generic",
        "",
        .LLVMCodeGenLevelDefault,
        .LLVMRelocPIC,
        .LLVMCodeModelDefault,
    );
    defer target_machine.LLVMDisposeTargetMachine(machine);

    const layout = target_machine.LLVMCreateTargetDataLayout(machine);
    target.LLVMSetModuleDataLayout(module, layout);

    var emitErr: [*c]u8 = null;
    if (target_machine.LLVMTargetMachineEmitToFile(machine, module, path, .LLVMObjectFile, &emitErr) != 0) {
        if (emitErr) |errMsg| {
            std.debug.print("Failed to emit object file: {s}\n", .{errMsg});
            core.LLVMDisposeMessage(errMsg);
        }
        return error.LLVMEmitError;
    }
}

fn startupLLVM() void {
    _ = target.LLVMInitializeNativeTarget();
    _ = target.LLVMInitializeNativeAsmPrinter();
    _ = target.LLVMInitializeNativeAsmParser();
}
