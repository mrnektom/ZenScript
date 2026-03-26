# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Workflow

Always use plan mode (EnterPlanMode) before starting non-trivial tasks. Explore the relevant code first, then present a plan for approval. Ask the user about any non-obvious or ambiguous details before implementing — do not make assumptions about intended behavior, especially around language semantics, type system rules, and error handling strategies.

## Project Overview

ZenScript is a compiler for a custom programming language, written in Zig. It compiles `.zs` source files through a multi-stage pipeline targeting LLVM. The project also has Node.js bindings via napi.

## Build Commands

```bash
zig build                          # Build everything
zig build run -- -i <file.zs>     # Run compiler on a .zs file
zig build test                     # Run all tests (module + executable)
npm run build                      # Build Node.js addon
npm test                           # Test Node.js addon
```

Requires Zig >= 0.15.2. Dependencies (LLVM bindings, napi) are fetched automatically by the Zig build system.

## Compilation Pipeline

The pipeline is orchestrated by `src/Pipline.zig` (note the typo — this is the actual filename) and flows through these stages:

```
.zs source → Tokenizer → Parser → Analyzer → IRGen → LLVMCodeGen
```

1. **Tokenizer** (`src/tokens/Tokenizer.zig`) — Lexes source into `ZSToken`s (defined in `src/tokens/ZSToken.zig`). Skips whitespace, tracks positions/lines.
2. **Parser** (`src/Parser.zig`) — Recursive descent parser producing an AST. Supports variable declarations (`let`/`const`), function declarations, external functions, expressions (numbers, strings, calls, references), and type annotations.
3. **Analyzer** (`src/analyze/analyzer.zig`) — Walks the AST, builds a scoped symbol table, performs type inference, and detects undefined references and type errors. Error reporting includes source locations.
4. **IR Generator** (`src/ir/IRGen.zig`) — Lowers AST to `ZSIR` instructions (assignments, calls) with generated temporaries (x0, x1, ...).
5. **LLVM CodeGen** (`src/codegen/LLVMCodeGen.zig`) — Partially implemented. Currently commented out in the pipeline.

## Key Architecture Details

- **AST types** live in `src/ast/` — `ast_node.zig` is the top-level union (stmt/expr). Statements: `zs_stmt_var.zig` (variables), `zs_stmt_fn.zig` (functions). Expressions: `zs_expr.zig` (union of number/string/call/reference).
- **Symbol table** is a stack of scopes (`src/analyze/symbol_table_stack.zig`) using `StringHashMap`. Symbols carry type signatures defined in `src/analyze/symbol_signature.zig` (number, string, unknown, function).
- **Error reporting** uses `src/analyze/AnalazeError.zig` (note typo) with precise source locations computed by helpers in `src/helpers/SourceHelpers.zig`.
- **CLI args** parsed in `src/args/Args.zig` — expects `-i <filepath>`.
- **Entry point**: `src/main.zig`. Node.js entry: `src/nodemodule.zig`.

## Naming Conventions

- Public types use PascalCase prefixed with `ZS`: `ZSModule`, `ZSAstNode`, `ZSToken`, `ZSIR`
- File names match the type they define (e.g., `ZSToken.zig` contains token type, `Tokenizer.zig` contains tokenizer)
- Each compilation phase is a self-contained module with clear interfaces between stages
- Memory management follows Zig allocator patterns with explicit `deinit()` methods

## Current State

Tokenizer, parser, analyzer, and IR generation are functional. LLVM codegen is scaffolded but incomplete and disabled in the pipeline. Language features like loops, conditionals, imports, and full function bodies are not yet implemented.
