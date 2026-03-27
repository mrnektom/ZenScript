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
) !types.LLVMModuleRef {
    startupLLVM();

    const module: types.LLVMModuleRef = core.LLVMModuleCreateWithName("zs_module");

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

    core.LLVMPositionBuilderAtEnd(builder, entry);

    var locals = std.StringHashMap(LocalVar).init(allocator);
    defer locals.deinit();

    for (instructions.instructions) |instruction| {
        try generateInstruction(builder, module, &locals, &instruction, allocator);
    }

    _ = core.LLVMBuildRet(builder, null);

    return module;
}

fn generateInstruction(
    builder: types.LLVMBuilderRef,
    module: types.LLVMModuleRef,
    locals: *std.StringHashMap(LocalVar),
    instruction: *const ir.ZSIR,
    allocator: std.mem.Allocator,
) std.mem.Allocator.Error!void {
    switch (instruction.*) {
        .assign => try generateAssign(builder, locals, instruction.assign),
        .call => try generateCall(builder, module, locals, instruction.call, allocator),
        .fn_decl => try generateFnDecl(module, instruction.fn_decl, allocator),
        .fn_def => try generateFnDef(builder, module, instruction.fn_def, allocator),
        .ret => generateRet(builder, locals, instruction.ret),
        .branch => try generateBranch(builder, module, locals, instruction.branch, allocator),
        .compare => try generateCompare(builder, locals, instruction.compare, allocator),
        .module_init => try generateModuleInit(builder, module, instruction.module_init, allocator),
    }
}

fn generateFnDecl(module: types.LLVMModuleRef, decl: ir.ZSIRFnDecl, allocator: std.mem.Allocator) !void {
    const paramCount: c_uint = @intCast(decl.argTypes.len);
    var paramTypes: [16]types.LLVMTypeRef = undefined;
    for (decl.argTypes, 0..) |argType, i| {
        paramTypes[i] = mapType(argType);
    }

    const retType = mapType(decl.retType);
    const funcType = core.LLVMFunctionType(retType, &paramTypes, paramCount, 0);
    const nameZ = try allocator.dupeZ(u8, decl.name);
    defer allocator.free(nameZ);

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
    const dlsymFunc = core.LLVMGetNamedFunction(module, "dlsym");
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

    var callArgs: [16]types.LLVMValueRef = undefined;
    var i: c_uint = 0;
    while (i < paramCount) : (i += 1) {
        callArgs[i] = core.LLVMGetParam(wrapperFunc, i);
    }

    const isVoid = core.LLVMGetTypeKind(retType) == .LLVMVoidTypeKind;
    const resultName: [*:0]const u8 = if (isVoid) "" else "result";
    const callResult = core.LLVMBuildCall2(builder, funcType, fptr, &callArgs, paramCount, resultName);

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
    var paramTypes: [16]types.LLVMTypeRef = undefined;
    for (def.argTypes, 0..) |argType, i| {
        paramTypes[i] = mapType(argType);
    }

    const retType = mapType(def.retType);
    const funcType = core.LLVMFunctionType(retType, &paramTypes, paramCount, 0);
    const nameZ = try allocator.dupeZ(u8, def.name);
    defer allocator.free(nameZ);
    const func = core.LLVMAddFunction(module, nameZ.ptr, funcType);

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
        try generateInstruction(builder, module, &fnLocals, &inst, allocator);
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
) !void {
    // Load the condition value
    var condVal: types.LLVMValueRef = undefined;
    if (locals.get(branch.condition)) |local| {
        condVal = core.LLVMBuildLoad2(builder, local.ty, local.ptr, "cond");
    } else {
        // Condition should always be in locals
        return;
    }

    // If this branch produces a value, allocate storage for the result before branching
    var resultPtr: types.LLVMValueRef = null;
    const resultTy = core.LLVMInt32Type();
    if (branch.resultName != null) {
        resultPtr = core.LLVMBuildAlloca(builder, resultTy, "ifres");
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
        try generateInstruction(builder, module, locals, &inst, allocator);
    }
    // Store then result if producing a value
    const thenTerm = core.LLVMGetBasicBlockTerminator(core.LLVMGetInsertBlock(builder));
    if (thenTerm == null) {
        if (resultPtr != null) {
            if (branch.thenResult) |thenResName| {
                if (locals.get(thenResName)) |local| {
                    const val = core.LLVMBuildLoad2(builder, local.ty, local.ptr, "thenval");
                    _ = core.LLVMBuildStore(builder, val, resultPtr);
                }
            }
        }
        _ = core.LLVMBuildBr(builder, mergeBlock);
    }

    // Else block
    core.LLVMPositionBuilderAtEnd(builder, elseBlock);
    for (branch.elseBody) |inst| {
        try generateInstruction(builder, module, locals, &inst, allocator);
    }
    const elseTerm = core.LLVMGetBasicBlockTerminator(core.LLVMGetInsertBlock(builder));
    if (elseTerm == null) {
        if (resultPtr != null) {
            if (branch.elseResult) |elseResName| {
                if (locals.get(elseResName)) |local| {
                    const val = core.LLVMBuildLoad2(builder, local.ty, local.ptr, "elseval");
                    _ = core.LLVMBuildStore(builder, val, resultPtr);
                }
            }
        }
        _ = core.LLVMBuildBr(builder, mergeBlock);
    }

    // Merge block
    core.LLVMPositionBuilderAtEnd(builder, mergeBlock);

    // Register result in locals
    if (branch.resultName) |resName| {
        try locals.put(resName, LocalVar{ .ptr = resultPtr, .ty = resultTy });
    }
}

fn generateCompare(
    builder: types.LLVMBuilderRef,
    locals: *std.StringHashMap(LocalVar),
    cmp: ir.ZSIRCompare,
    allocator: std.mem.Allocator,
) !void {
    // Load LHS
    var lhsVal: types.LLVMValueRef = undefined;
    if (locals.get(cmp.lhs)) |local| {
        lhsVal = core.LLVMBuildLoad2(builder, local.ty, local.ptr, "lhs");
    } else {
        return;
    }

    // Load RHS
    var rhsVal: types.LLVMValueRef = undefined;
    if (locals.get(cmp.rhs)) |local| {
        rhsVal = core.LLVMBuildLoad2(builder, local.ty, local.ptr, "rhs");
    } else {
        return;
    }

    const pred: types.LLVMIntPredicate = if (std.mem.eql(u8, cmp.op, "=="))
        .LLVMIntEQ
    else
        .LLVMIntNE;

    const cmpResult = core.LLVMBuildICmp(builder, pred, lhsVal, rhsVal, "cmp");

    // Store result as i1 (boolean)
    const ptr = core.LLVMBuildAlloca(builder, core.LLVMInt1Type(), "cmpres");
    _ = core.LLVMBuildStore(builder, cmpResult, ptr);
    try locals.put(cmp.resultName, LocalVar{ .ptr = ptr, .ty = core.LLVMInt1Type() });

    _ = allocator;
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
                // local is a ZSString struct {i32, i8*}; extract len and ptr fields
                const strStruct = core.LLVMBuildLoad2(builder, local.ty, local.ptr, "str");
                const strLen = core.LLVMBuildExtractValue(builder, strStruct, 0, "strlen");
                const strPtr = core.LLVMBuildExtractValue(builder, strStruct, 1, "strptr");

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

                const dlopenFunc = core.LLVMGetNamedFunction(module, "dlopen");
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

    const fnNameZ = try allocator.dupeZ(u8, call.fnName);
    defer allocator.free(fnNameZ);
    const funcRef = core.LLVMGetNamedFunction(module, fnNameZ.ptr);
    if (funcRef == null) return;

    const funcType = core.LLVMGlobalGetValueType(funcRef);

    var args: [16]types.LLVMValueRef = undefined;
    for (call.argNames, 0..) |argName, i| {
        if (locals.get(argName)) |local| {
            args[i] = core.LLVMBuildLoad2(builder, local.ty, local.ptr, "arg");
        }
    }

    const argCount: c_uint = @intCast(call.argNames.len);

    const retType = core.LLVMGetReturnType(funcType);
    const isVoid = core.LLVMGetTypeKind(retType) == .LLVMVoidTypeKind;
    const resultName: [*:0]const u8 = if (isVoid) "" else "call_result";

    const result = core.LLVMBuildCall2(builder, funcType, funcRef, &args, argCount, resultName);

    // Store non-void results so they can be referenced later
    if (!isVoid) {
        const ptr = core.LLVMBuildAlloca(builder, retType, "callres");
        _ = core.LLVMBuildStore(builder, result, ptr);
        try locals.put(call.resultName, LocalVar{ .ptr = ptr, .ty = retType });
    }
}

fn mapType(name: []const u8) types.LLVMTypeRef {
    if (std.mem.eql(u8, name, "number")) {
        return core.LLVMInt32Type();
    } else if (std.mem.eql(u8, name, "boolean")) {
        return core.LLVMInt1Type();
    } else if (std.mem.eql(u8, name, "string")) {
        return getStringType();
    } else if (std.mem.eql(u8, name, "c_string")) {
        return core.LLVMPointerType(core.LLVMInt8Type(), 0);
    } else if (std.mem.eql(u8, name, "void")) {
        return core.LLVMVoidType();
    } else {
        return core.LLVMVoidType();
    }
}

fn getStringType() types.LLVMTypeRef {
    var elems: [2]types.LLVMTypeRef = [_]types.LLVMTypeRef{ core.LLVMInt32Type(), core.LLVMPointerType(core.LLVMInt8Type(), 0) };
    return core.LLVMStructType(&elems, 2, 0);
}

fn getValue(builder: types.LLVMBuilderRef, value: *const ir.ZSIRValue) !types.LLVMValueRef {
    return switch (value.*) {
        .number => core.LLVMConstInt(core.LLVMInt32Type(), @intCast(value.number), 1),
        .string => getStringValue(builder, value.string),
        .boolean => core.LLVMConstInt(core.LLVMInt1Type(), if (value.boolean) 1 else 0, 0),
    };
}

fn getStringValue(builder: types.LLVMBuilderRef, value: [*:0]const u8) !types.LLVMValueRef {
    const zStr: []const u8 = std.mem.span(value);
    const arrTy = core.LLVMArrayType(core.LLVMInt8Type(), @intCast(zStr.len));
    const ptr = core.LLVMBuildAlloca(builder, arrTy, "strVal");
    const str = core.LLVMConstString(value, @intCast(zStr.len), 1);
    _ = core.LLVMBuildStore(builder, str, ptr);
    var values: [2]types.LLVMValueRef = [_]types.LLVMValueRef{ core.LLVMConstInt(core.LLVMInt32Type(), zStr.len, 0), ptr };
    return core.LLVMConstStruct(&values, 2, 0);
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
