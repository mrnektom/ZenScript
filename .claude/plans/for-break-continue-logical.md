# Plan: C-style `for` loops, `break`/`continue`, logical operators `&&`/`||`/`!`

## Overview

Three features, implemented in dependency order:
1. **`break`/`continue`** — needed by `for` loops, standalone useful for `while`
2. **C-style `for` loops** — desugars to `while` + init + step at IR level
3. **Logical operators `&&`, `||`, `!`** — `&&`/`||` with short-circuit evaluation

---

## Feature 1: `break` and `continue`

### Design

`break` and `continue` are statements (not expressions — they don't produce values). They generate IR instructions that codegen translates to `br` to the appropriate loop basic block.

### Changes

**`src/tokens/zs_token.zig`** — no change needed, `break`/`continue` are just identifiers that get recognized by the parser.

**`src/parser.zig`**:
- Add `"break"` and `"continue"` to `isKeyword()` list (line 279)
- Add `nextBreak()` and `nextContinue()` parsing functions — simple keyword match, no arguments
- Wire into `nextExpr()` before other expressions

**`src/ast/zs_expr.zig`**:
- Add `ZSBreak` struct: `{ startPos, endPos }` (no deinit needed)
- Add `ZSContinue` struct: `{ startPos, endPos }` (no deinit needed)
- Add `break_expr` and `continue_expr` variants to `ZSExprType` enum and `ZSExpr` union
- Update `deinit`, `start`, `end`, `clone` switch statements

**`src/analyzer/analyzer.zig`**:
- Add `analyzeBreak`/`analyzeContinue` — return `.void`, optionally check that we're inside a loop (track `inLoop: bool` on the analyzer struct)

**`src/ir/zsir.zig`**:
- Add `ZSIRBreak` and `ZSIRContinue` structs (empty — they carry no data, just signal control flow)
- Add `break_expr` and `continue_expr` to `ZSIRType` enum and `ZSIR` union
- Update `deinit` and `format` switches

**`src/ir/ir_gen.zig`**:
- `generateExpr` already has a big switch on expr types — add cases for `break_expr` and `continue_expr` that append the corresponding IR instruction and return `""`

**`src/codegen/llvm_codegen.zig`**:
- Track loop context: add `loopCondBlock` and `loopAfterBlock` as optional `LLVMBasicBlockRef` parameters (or store in a small struct passed through `generateInstruction`). **Simplest approach**: add two module-level `threadlocal` variables or pass them via a `LoopContext` struct. Since `generateInstruction` is called recursively, the cleanest approach is to add `loop_cond_block: ?types.LLVMBasicBlockRef` and `loop_after_block: ?types.LLVMBasicBlockRef` fields to a new `CodegenContext` struct, or simply pass them as extra optional params to `generateInstruction`.

  **Chosen approach**: Add a `LoopContext` struct and thread it through `generateInstruction` and all functions that can contain loop bodies (which is all of them due to nesting). Change signature:
  ```
  fn generateInstruction(builder, module, locals, instruction, allocator, loopCtx: ?LoopContext) !void
  ```

  `LoopContext = struct { condBlock: LLVMBasicBlockRef, afterBlock: LLVMBasicBlockRef }`

- In `generateLoop`: create `LoopContext` from `condBlock`/`afterBlock`, pass to body instructions
- In `generateInstruction`: `.break_expr => LLVMBuildBr(builder, loopCtx.?.afterBlock)`, `.continue_expr => LLVMBuildBr(builder, loopCtx.?.condBlock)`
- Thread `loopCtx` through `generateBranch`, `generateLoop` (for nested loops — inner loop creates new context, restores outer), `generateFnDef` (passes `null` — break/continue don't cross function boundaries)
- Top-level `generateLLVMModule` passes `null` as initial loopCtx

---

## Feature 2: C-style `for` loops

### Syntax
```
for (let i = 0; i < 10; i = i + 1) {
    print(i)
}
```

### Design

Desugar at IR level to: init + while(condition) { body; step }. This avoids adding a new IR instruction type — reuses `ZSIRLoop`.

Actually, the step needs to run after the body but before the condition re-evaluation. The existing `ZSIRLoop` has `condition` and `body` — we can append step instructions to the end of `body` in IR gen. No new IR type needed.

### Changes

**`src/parser.zig`**:
- Add `"for"` to `isKeyword()` list
- Add `nextForExpr()`: parse `for` `(` init `;` condition `;` step `)` body
  - `init`: a `let`/`const` statement (parsed with `nextVarDeclaration`)
  - `condition`: an expression
  - `step`: a reassignment expression (parsed with `nextReassignment`)
  - `body`: an expression (typically a block)
- Wire into `nextExpr()` alongside `while_expr`

**`src/ast/zs_expr.zig`**:
- Add `ZSForExpr` struct: `{ init: *ZSAstNode, condition: *ZSExpr, step: *ZSAstNode, body: *ZSExpr, startPos, endPos }`
  - `init` is a statement (var declaration), `step` is a statement (reassignment)
- Add `for_expr` variant to `ZSExprType` and `ZSExpr` union
- Update all switches

**`src/analyzer/analyzer.zig`**:
- Add `analyzeForExpr` — analyze init, condition, body, step in order. Return `.void`.

**`src/ir/ir_gen.zig`**:
- Add `generateForExpr`:
  1. Generate init (as a statement — append to current instructions)
  2. Generate condition into separate list (like while)
  3. Generate body into separate list
  4. Generate step into the body list (append after body instructions)
  5. Emit `ZSIRLoop{ .condition = condInstructions, .conditionName = condName, .body = bodyInstructions }`
- No new IR type needed — reuses `ZSIRLoop`

**Codegen**: No changes — `generateLoop` already handles `ZSIRLoop`.

---

## Feature 3: Logical operators `&&`, `||`, `!`

### Design

**`&&` and `||`** require short-circuit evaluation:
- `a && b` → if `a` is false, result is false (don't evaluate `b`)
- `a || b` → if `a` is true, result is true (don't evaluate `b`)

These are **desugared to `ZSIRBranch`** (if/else) at IR level — no new IR instructions needed.

**`!`** is a unary prefix operator. It needs a new AST node and IR instruction.

### Changes

**`src/parser.zig`**:
- Add `&&` and `||` to `nextBinaryRhs()` operator list
- Add `nextUnaryNot()`: if token is `!`, consume it, parse the next primary expression, wrap in `ZSUnary{ .op = "!", .operand = expr }`
- Wire `nextUnaryNot` into `nextExpr()` before other primary expressions

**`src/ast/zs_expr.zig`**:
- Add `ZSUnary` struct: `{ op: []const u8, operand: *ZSExpr, startPos, endPos }`
- Add `unary` variant to enum/union, update all switches

**`src/analyzer/analyzer.zig`**:
- `analyzeBinary`: add `&&`/`||` → return `.boolean`
- Add `analyzeUnary`: analyze operand, return `.boolean` for `!`

**`src/ir/ir_gen.zig`**:
- `generateBinary`: special-case `&&` and `||` to desugar to `ZSIRBranch`:
  - `a && b`: evaluate `a`. If true, result = `b`. If false, result = false.
  - `a || b`: evaluate `a`. If true, result = true. If false, result = `b`.

  This reuses the existing `ZSIRBranch` mechanism with `thenBody`/`elseBody`/`resultName`.

- Add `generateUnary`: for `!`, generate operand, then emit a `ZSIRCompare` with `op = "=="` comparing the operand to `0` (false). This produces `true` when operand is `false`.

  Actually simpler: add a new `ZSIRNot` IR instruction: `{ resultName, operand }`.

**`src/ir/zsir.zig`**:
- Add `ZSIRNot`: `{ resultName: []const u8, operand: []const u8 }`
- Add `not` to enum/union, update switches

**`src/codegen/llvm_codegen.zig`**:
- `generateNot`: load operand (i1), `LLVMBuildNot` or `LLVMBuildICmp(EQ, val, 0)`, store result as i1
- No special codegen for `&&`/`||` — they desugar to `branch` which is already implemented

---

## File change summary

| File | Changes |
|------|---------|
| `src/ast/zs_expr.zig` | Add `ZSBreak`, `ZSContinue`, `ZSForExpr`, `ZSUnary` types + union variants |
| `src/parser.zig` | Parse `for`, `break`, `continue`, `!`, `&&`, `||` |
| `src/analyzer/analyzer.zig` | Analyze new expr types, track `inLoop` for break/continue validation |
| `src/ir/zsir.zig` | Add `ZSIRBreak`, `ZSIRContinue`, `ZSIRNot` |
| `src/ir/ir_gen.zig` | Generate IR for new exprs, desugar `for`→while, `&&`/`||`→branch |
| `src/codegen/llvm_codegen.zig` | Add `LoopContext` threading, `break`/`continue` codegen, `not` codegen |

## Verification

```zs
// Test for loop + break + continue
for (let i = 0; i < 10; i = i + 1) {
    if (i == 5) break
    if (i == 3) continue
    print(i)
}
// Expected: 0 1 2 4

// Test logical operators
let a = true
let b = false
if (a && !b) print(1)
if (a || b) print(2)
// Expected: 1 2
```

Run: `zig build test && zig build run -- -i examples/for_test.zs -r`
