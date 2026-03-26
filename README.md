# ZenScript language

A compiler for a custom programming language, written in Zig, targeting LLVM.

## Building

```bash
zig build                          # Build everything
zig build run -- -i <file.zs>     # Run compiler on a .zs file
zig build run -- -i <file.zs> -r  # Compile and execute
zig build run -- -i <file.zs> -dump-ir  # Dump LLVM IR
zig build test                     # Run all tests
```

Requires Zig >= 0.15.2.

## Basic syntax

### Variables

```zs
let x = 10        // mutable variable
const y = 42      // immutable constant
x = 50            // reassignment (only for let)
```

### Functions

```zs
// Expression body
fn get_ten(): number = 10

// Block body
fn add(a: number, b: number): number {
    return a
}

// External function declaration (no body)
external fn print_number(n: number): void

// Function overloading
fn process(x: number): number = x
fn process(x: string): string = x
```

### Types

Supported types: `number`, `string`, `boolean`, `void`.

Type annotations are used on function arguments and return types:

```zs
fn greet(name: string): string = name
fn check(x: number): boolean = true
```

### Expressions

```zs
// Literals
42
"hello"
true
false

// Function calls
print_number(10)
add(1, 2)

// Binary operators (== and !=)
x == 10
x != 0

// If/else (optional parentheses around condition)
if x == 10 { return 1 } else { return 0 }
if (condition) expr1 else expr2

// Blocks
{
    let a = 1
    let b = 2
    a
}

// Return
return value
return
```

### Imports and exports

```zs
// lib.zs
export fn get_ten(): number = 10
export let x = 42

// main.zs
import { get_ten, x as y } from "./lib.zs"
print_number(get_ten())
print_number(y)
```

Features:
- Named imports with aliasing (`as`)
- Paths resolved relative to the importing file
- Circular import detection
- Recursive dependency compilation

## Compilation pipeline

```
.zs source → Tokenizer → Parser → Analyzer → IRGen → LLVMCodeGen → MCJIT execution
```
