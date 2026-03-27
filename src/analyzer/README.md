# Analyzer

Semantic analysis pass. Walks the AST to resolve symbols, infer types, and report errors.

## Files

- **analyzer.zig** — Main analysis pass over the AST.
- **analyze_error.zig** — Error types and source-location-aware error reporting.
- **symbol.zig** — Symbol representation used in the symbol table.
- **symbol_signature.zig** — Type signatures (number, string, unknown, function).
- **symbol_table.zig** — Single-scope symbol table backed by `StringHashMap`.
- **symbol_table_stack.zig** — Stack of symbol tables for nested scope lookups.
