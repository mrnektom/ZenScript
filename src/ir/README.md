# IR

Intermediate representation between the AST and LLVM code generation.

## Files

- **ir_gen.zig** — Lowers AST nodes into `ZSIR` instructions, generating temporaries (x0, x1, ...).
- **zsir.zig** — `ZSIR` instruction set definition (assignments, calls).
