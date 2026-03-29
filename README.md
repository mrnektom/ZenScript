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

Supported types: `number` (i32), `long` (i64), `int` (alias for number), `short` (i16), `byte` (i8), `char` (i8), `boolean`, `void`, arrays, user-defined structs, and enums.

Type annotations are used on function arguments and return types:

```zs
fn check(x: number): boolean = true
fn greet(name: String): void = print(name)
fn first(arr: [number]): number = arr[0]
```

### Structs

```zs
struct Point { x: number, y: number }

// Generic structs
struct Pair<T, U> { first: T, second: U }

// Struct init and field access
let p = Point { x: 10, y: 20 }
let v = p.x

// Export structs for use in other modules
export struct String { len: number, data: Pointer<number> }
```

### Enums and match

```zs
enum Option {
  Some(number),
  None
}

let x = Option.Some(42)
let y = Option.None

let result = match x {
  Option.Some(v) -> v + 1,
  Option.None -> 0
}

// Import variant names into scope
use Option.{Some, None}
let z = Some(10)
```

Enums are tagged unions (`{ i32 tag, payload }`). Match expressions require exhaustive coverage of all variants. Payload binding (`v` above) extracts the variant's value.

### Pointers

```zs
let px = ptr(val)      // create a pointer
let v = deref(px)      // dereference a pointer
```

Generic pointer type annotation: `Pointer<number>`.

### Char

```zs
let c = 'a'
let newline = '\n'
let zero = '\0'
```

Char is an 8-bit value (`i8` in LLVM). Supported escapes: `\n`, `\t`, `\r`, `\\`, `\'`, `\0`.

### Arrays

```zs
let arr = [1, 2, 3]
let first = arr[0]       // index access
arr[1] = 42              // indexed assignment (let only)
let len = arr.length     // array length

let chars = ['h', 'i']   // array of char

// Repeat syntax: [value; count]
let zeros = ['\0'; 128]  // 128 null bytes
let ones = [1; 10]       // 10 elements, all 1
```

Arrays are fixed-size and stack-allocated (`alloca [N x T]` in LLVM). Array type annotation: `[number]`, `[char]`.

### Expressions

```zs
// Literals
42
"hello"
'a'
true
false

// Function calls
print(greeting)
add(1, 2)

// Arithmetic operators
x + y
x - y
x * y
x / y
x % y

// Comparison operators
x == 10
x != 0
x > 0
x < 100
x >= 1
x <= 99

// If/else (optional parentheses around condition)
if x == 10 { return 1 } else { return 0 }
if (condition) expr1 else expr2

// While loops
while (val > 0) {
    val = val - 1
}

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
export struct Point { x: number, y: number }

// main.zs
import { get_ten, x as y } from "./lib.zs"
print(get_ten())
```

Re-export symbols from another module:

```zs
// prelude.zs
export { String } from "./string.zs"
export fn print(s: String): void { ... }
```

Features:
- Named imports with aliasing (`as`)
- `export { ... } from "..."` for re-exporting (import + export in one statement)
- Only `export struct` is visible to dependent modules
- Paths resolved relative to the importing file
- Circular import detection
- Recursive dependency compilation

### Standard library

The `stdlib/` directory is auto-imported as a prelude. It provides:
- `print(s: String): void` — print a string
- `print(n: number): void` — print a number (overloaded)
- `read_line(): String` — read a line from stdin
- `String` struct (re-exported from `string.zs`)

### Intrinsics

Low-level intrinsics available for systems programming:
- `__syscall3(nr, arg1, arg2, arg3): number` — Linux syscall

## Compilation pipeline

```
.zs source → Tokenizer → Parser → Analyzer → IRGen → LLVMCodeGen → MCJIT / executable
```

Compilation modes:
- `-r` — JIT execution via MCJIT
- `-o <path>` — compile to native executable (via LLVM object file + linker)
- `-dump-ir` — dump LLVM IR to stdout
