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
        .store => generateStore(builder, locals, instruction.store),
        .call => try generateCall(builder, module, locals, instruction.call, allocator),
        .fn_decl => try generateFnDecl(module, instruction.fn_decl, allocator),
        .fn_def => try generateFnDef(builder, module, instruction.fn_def, allocator),
        .ret => generateRet(builder, locals, instruction.ret),
        .branch => try generateBranch(builder, module, locals, instruction.branch, allocator),
        .compare => try generateCompare(builder, locals, instruction.compare, allocator),
        .arith => try generateArith(builder, locals, instruction.arith, allocator),
        .loop => try generateLoop(builder, module, locals, instruction.loop, allocator),
        .module_init => try generateModuleInit(builder, module, instruction.module_init, allocator),
        .array_init => try generateArrayInit(builder, locals, instruction.array_init),
        .index_access => try generateIndexAccess(builder, locals, instruction.index_access),
        .index_store => generateIndexStore(builder, locals, instruction.index_store),
        // Struct/pointer instructions — stubs for future implementation
        .struct_init => {},
        .field_access => {},
        .ptr_op => try generatePtrOp(builder, locals, instruction.ptr_op),
        .deref_op => {},
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
) !void {
    const currentFunc = core.LLVMGetBasicBlockParent(core.LLVMGetInsertBlock(builder));
    const condBlock = core.LLVMAppendBasicBlock(currentFunc, "while.cond");
    const bodyBlock = core.LLVMAppendBasicBlock(currentFunc, "while.body");
    const afterBlock = core.LLVMAppendBasicBlock(currentFunc, "while.after");

    // Branch to condition block
    _ = core.LLVMBuildBr(builder, condBlock);

    // Condition block: evaluate condition
    core.LLVMPositionBuilderAtEnd(builder, condBlock);
    for (loop.condition) |inst| {
        try generateInstruction(builder, module, locals, &inst, allocator);
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
        try generateInstruction(builder, module, locals, &inst, allocator);
    }
    // Check if body has a terminator (e.g., return), if not jump back to condition
    const bodyTerm = core.LLVMGetBasicBlockTerminator(core.LLVMGetInsertBlock(builder));
    if (bodyTerm == null) {
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

    // Handle intrinsics
    if (std.mem.eql(u8, call.fnName, "__syscall3")) {
        try generateSyscall3(builder, locals, call);
        return;
    }
    if (std.mem.eql(u8, call.fnName, "__ptr_to_int")) {
        try generatePtrToInt(builder, locals, call);
        return;
    }
    if (std.mem.eql(u8, call.fnName, "__str_len")) {
        try generateStrLen(builder, locals, call);
        return;
    }
    if (std.mem.eql(u8, call.fnName, "__read_line")) {
        try generateReadLine(builder, module, locals, call, allocator);
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

fn generatePtrToInt(
    builder: types.LLVMBuilderRef,
    locals: *std.StringHashMap(LocalVar),
    call: ir.ZSIRCall,
) !void {
    if (call.argNames.len != 1) return;

    if (locals.get(call.argNames[0])) |local| {
        const i64Type = core.LLVMInt64Type();

        if (core.LLVMGetTypeKind(local.ty) == .LLVMPointerTypeKind) {
            // Pointer type: load the pointer, then PtrToInt
            const ptrVal = core.LLVMBuildLoad2(builder, local.ty, local.ptr, "ptrval");
            const ptrInt = core.LLVMBuildPtrToInt(builder, ptrVal, i64Type, "ptrint");
            const res = core.LLVMBuildAlloca(builder, i64Type, "ptrintres");
            _ = core.LLVMBuildStore(builder, ptrInt, res);
            try locals.put(call.resultName, LocalVar{ .ptr = res, .ty = i64Type });
        } else {
            // String struct: extract ptr field at index 1
            const strStruct = core.LLVMBuildLoad2(builder, local.ty, local.ptr, "str");
            const strPtr = core.LLVMBuildExtractValue(builder, strStruct, 1, "strptr");
            const ptrInt = core.LLVMBuildPtrToInt(builder, strPtr, i64Type, "ptrint");
            const ptr = core.LLVMBuildAlloca(builder, i64Type, "ptrintres");
            _ = core.LLVMBuildStore(builder, ptrInt, ptr);
            try locals.put(call.resultName, LocalVar{ .ptr = ptr, .ty = i64Type });
        }
    }
}

fn generateStrLen(
    builder: types.LLVMBuilderRef,
    locals: *std.StringHashMap(LocalVar),
    call: ir.ZSIRCall,
) !void {
    if (call.argNames.len != 1) return;

    if (locals.get(call.argNames[0])) |local| {
        const strStruct = core.LLVMBuildLoad2(builder, local.ty, local.ptr, "str");
        // ZSString = { i32 len, i8* ptr }, extract len at index 0
        const strLen = core.LLVMBuildExtractValue(builder, strStruct, 0, "strlen");

        const ptr = core.LLVMBuildAlloca(builder, core.LLVMInt32Type(), "strlenres");
        _ = core.LLVMBuildStore(builder, strLen, ptr);
        try locals.put(call.resultName, LocalVar{ .ptr = ptr, .ty = core.LLVMInt32Type() });
    }
}

fn generatePtrOp(
    builder: types.LLVMBuilderRef,
    locals: *std.StringHashMap(LocalVar),
    op: ir.ZSIRPtrOp,
) !void {
    const operand = locals.get(op.operand) orelse return;
    const ptrType = core.LLVMPointerType(core.LLVMInt8Type(), 0);

    var resultPtr: types.LLVMValueRef = undefined;

    if (core.LLVMGetTypeKind(operand.ty) == .LLVMArrayTypeKind) {
        // Array: GEP to get pointer to first element
        var indices: [2]types.LLVMValueRef = .{
            core.LLVMConstInt(core.LLVMInt32Type(), 0, 0),
            core.LLVMConstInt(core.LLVMInt32Type(), 0, 0),
        };
        resultPtr = core.LLVMBuildGEP2(builder, operand.ty, operand.ptr, &indices, 2, "arrptr");
    } else {
        // Scalar: the alloca itself is already a pointer
        resultPtr = operand.ptr;
    }

    // Store the pointer into an alloca so it can be loaded later
    const alloca = core.LLVMBuildAlloca(builder, ptrType, "ptrop");
    _ = core.LLVMBuildStore(builder, resultPtr, alloca);
    try locals.put(op.resultName, LocalVar{ .ptr = alloca, .ty = ptrType });
}

fn generateReadLine(
    builder: types.LLVMBuilderRef,
    module: types.LLVMModuleRef,
    locals: *std.StringHashMap(LocalVar),
    call: ir.ZSIRCall,
    allocator: std.mem.Allocator,
) !void {
    _ = allocator;
    _ = module;

    const i32Type = core.LLVMInt32Type();
    const i64Type = core.LLVMInt64Type();
    const i8Type = core.LLVMInt8Type();
    const ptrType = core.LLVMPointerType(i8Type, 0);

    // Allocate 1024-byte buffer on stack
    const bufSize = core.LLVMConstInt(i32Type, 1024, 0);
    const buf = core.LLVMBuildArrayAlloca(builder, i8Type, bufSize, "readbuf");

    // syscall read(0, buf, 1024)
    var sysParams: [4]types.LLVMTypeRef = .{ i64Type, i64Type, i64Type, i64Type };
    const sysFnType = core.LLVMFunctionType(i64Type, &sysParams, 4, 0);
    const sysAsm = core.LLVMGetInlineAsm(
        sysFnType,
        @constCast("syscall"),
        7,
        @constCast("={rax},{rax},{rdi},{rsi},{rdx},~{rcx},~{r11},~{memory}"),
        56,
        1,
        0,
        .LVMInlineAsmDialectATT,
        0,
    );

    const bufInt = core.LLVMBuildPtrToInt(builder, buf, i64Type, "bufint");
    var readArgs: [4]types.LLVMValueRef = .{
        core.LLVMConstInt(i64Type, 0, 0), // syscall nr = 0 (read)
        core.LLVMConstInt(i64Type, 0, 0), // fd = 0 (stdin)
        bufInt,
        core.LLVMConstInt(i64Type, 1024, 0),
    };
    const bytesRead64 = core.LLVMBuildCall2(builder, sysFnType, sysAsm, &readArgs, 4, "bytesread");
    var bytesRead = core.LLVMBuildTrunc(builder, bytesRead64, i32Type, "bytesread32");

    // Strip trailing newline: if bytesRead > 0 && buf[bytesRead-1] == '\n', bytesRead--
    const currentFunc = core.LLVMGetBasicBlockParent(core.LLVMGetInsertBlock(builder));
    const stripBlock = core.LLVMAppendBasicBlock(currentFunc, "strip");
    const doneBlock = core.LLVMAppendBasicBlock(currentFunc, "stripdone");

    const gtZero = core.LLVMBuildICmp(builder, .LLVMIntSGT, bytesRead, core.LLVMConstInt(i32Type, 0, 0), "gtz");
    _ = core.LLVMBuildCondBr(builder, gtZero, stripBlock, doneBlock);

    core.LLVMPositionBuilderAtEnd(builder, stripBlock);
    const lastIdx = core.LLVMBuildSub(builder, bytesRead, core.LLVMConstInt(i32Type, 1, 0), "lastidx");
    const lastPtr = core.LLVMBuildGEP2(builder, i8Type, buf, @constCast(&[_]types.LLVMValueRef{lastIdx}), 1, "lastptr");
    const lastChar = core.LLVMBuildLoad2(builder, i8Type, lastPtr, "lastch");
    const isNl = core.LLVMBuildICmp(builder, .LLVMIntEQ, lastChar, core.LLVMConstInt(i8Type, 10, 0), "isnl");
    const stripped = core.LLVMBuildSelect(builder, isNl, lastIdx, bytesRead, "stripped");
    _ = core.LLVMBuildBr(builder, doneBlock);

    core.LLVMPositionBuilderAtEnd(builder, doneBlock);
    // PHI for final length
    const phi = core.LLVMBuildPhi(builder, i32Type, "finallen");
    var phiVals: [2]types.LLVMValueRef = .{ bytesRead, stripped };
    const preStripBlock = core.LLVMGetPreviousBasicBlock(stripBlock);
    var phiBlocks: [2]types.LLVMBasicBlockRef = .{ preStripBlock, stripBlock };
    core.LLVMAddIncoming(phi, &phiVals, &phiBlocks, 2);

    bytesRead = phi;

    // Create ZSString struct { i32 len, i8* ptr }
    const strType = getStringType();
    const strPtr = core.LLVMBuildAlloca(builder, strType, "readstr");
    var strVal = core.LLVMGetUndef(strType);
    strVal = core.LLVMBuildInsertValue(builder, strVal, bytesRead, 0, "withlen");
    const bufAsPtr = core.LLVMBuildBitCast(builder, buf, ptrType, "bufptr");
    strVal = core.LLVMBuildInsertValue(builder, strVal, bufAsPtr, 1, "withptr");
    _ = core.LLVMBuildStore(builder, strVal, strPtr);
    try locals.put(call.resultName, LocalVar{ .ptr = strPtr, .ty = strType });
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

fn mapType(name: []const u8) types.LLVMTypeRef {
    if (std.mem.eql(u8, name, "number")) {
        return core.LLVMInt32Type();
    } else if (std.mem.eql(u8, name, "char")) {
        return core.LLVMInt8Type();
    } else if (std.mem.eql(u8, name, "boolean")) {
        return core.LLVMInt1Type();
    } else if (std.mem.eql(u8, name, "String")) {
        return getStringType();
    } else if (std.mem.eql(u8, name, "c_string")) {
        return core.LLVMPointerType(core.LLVMInt8Type(), 0);
    } else if (std.mem.eql(u8, name, "pointer")) {
        // Generic pointer type (opaque ptr)
        return core.LLVMPointerType(core.LLVMInt8Type(), 0);
    } else if (std.mem.eql(u8, name, "void")) {
        return core.LLVMVoidType();
    } else {
        // Unknown type (including struct names) — use opaque pointer as placeholder
        return core.LLVMPointerType(core.LLVMInt8Type(), 0);
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
        .char => core.LLVMConstInt(core.LLVMInt8Type(), @intCast(value.char), 0),
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
