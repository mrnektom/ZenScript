# Tokens

Lexical analysis stage. Converts raw source text into a stream of typed tokens.

## Files

- **tokenizer.zig** — Stateful lexer that scans `.zs` source code, skips whitespace, and tracks positions/lines.
- **zs_token.zig** — `ZSToken` struct and token type enum (keywords, operators, literals, identifiers).
