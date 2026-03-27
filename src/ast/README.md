# AST

Abstract syntax tree definitions produced by the parser.

## Files

- **ast_node.zig** — Root `ZSAstNode` union (statement or expression).
- **zs_stmt.zig** — Statement union (variable declaration, function declaration, reassignment).
- **zs_stmt_var.zig** — Variable declaration nodes (`let` / `const`).
- **zs_stmt_fn.zig** — Function declaration nodes.
- **zs_stmt_reassign.zig** — Variable reassignment nodes.
- **zs_expr.zig** — Expression union (number, string, call, reference).
- **zs_call.zig** — Function call expression nodes.
- **zs_type_notation.zig** — Type annotation nodes.
- **zs_import.zig** — Import statement nodes.
- **zs_module.zig** — Top-level module node containing all declarations.
