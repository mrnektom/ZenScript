# ZenScript Language Specification

> Current version. Reflects what is implemented and functional in the compiler pipeline.

---

## Compilation Pipeline

```
.zs source → Tokenizer → Parser → Analyzer → IRGen → (LLVMCodeGen — disabled)
```

---

## Variables

```zenscript
let x: number = 42      // mutable variable
const name = "hello"    // constant
x = 100                 // reassignment
```

Type annotation is optional — the analyzer infers types where possible.

---

## Types

| Type         | Description                 |
|--------------|-----------------------------|
| `number`     | numeric                     |
| `boolean`    | boolean                     |
| `char`       | character                   |
| `long`       | 64-bit integer              |
| `short`      | 16-bit integer              |
| `byte`       | 8-bit integer               |
| `T[]`        | array of T                  |
| `Pointer<T>` | pointer to T                |
| `SomeName`   | user-defined struct or enum |
| `Generic<T>` | instantiated generic type   |

---

## Functions

```zenscript
fn add(a: number, b: number): number = a + b

fn process<T>(value: T): T {
    return value
}

external fn print(n: number): void

export fn getTen(): number = 10
```

- Parameters and return type can be annotated explicitly.
- Generic type parameters are declared with `<T, U, ...>`.
- `external` declares a function implemented outside ZenScript.
- `export` marks a function visible to other modules.
- Function overloading is supported (same name, different signatures).

---

## Structs

```zenscript
struct Point { x: number, y: number }
struct Pair<T, U> { first: T, second: U }

let p = Point { x: 10, y: 20 }
let val = p.x
p.x = 5
```

- Fields are declared with explicit type annotations.
- Generic structs use `<T, U, ...>` parameter lists.
- Field access uses dot notation; chaining is supported (`a.b.c`).

---

## Enums

```zenscript
enum Option<T> { Some(T), None }
enum Result<T, E> { Ok(T), Err(E) }

let x = Option.Some(42)
```

- Variants can carry a payload type: `Some(T)`.
- Variants without payload are simple names: `None`.
- Generic enums use `<T, ...>` parameter lists.

---

## Pattern Matching

`match` is an expression and returns a value. Arms have the form `Pattern -> expr`. The `else` arm is a wildcard that
matches anything.

### Primitives

```zenscript
let result = match x {
    0    -> "zero",
    1    -> "one",
    else -> "other"
}
```

Supported for `number`, `boolean`, `char`, and `string` literals.

### Enums

```zenscript
let result = match x {
    Option.Some(v) -> v + 1,
    Option.None    -> 0
}
```

Payload variables are bound in the arm body.

### Structs

```zenscript
let result = match p {
    Point { x: 0, y } -> y,
    Point { x, y }    -> x + y
}
```

Fields can be matched by value (`x: 0`) or simply bound as a variable (`y`). Unmentioned fields are ignored.

### Wildcard

```zenscript
let result = match x {
    0    -> "zero",
    else -> "non-zero"
}
```

`else` must be the last arm. It binds no variable — use a preceding binding arm if the value is needed.

---

## Control Flow

### If

```zenscript
let y = if (x > 0) x else 0

if (flag) {
    doSomething()
} else {
    doOther()
}
```

`if` is an expression — both branches must produce compatible types.

### While

```zenscript
while (cond) {
    body
}
```

### For

```zenscript
for (let i = 0; i < 10; i = i + 1) {
    if (i == 3) continue
    if (i == 7) break
    print(i)
}
```

### Blocks

```zenscript
let z = {
    let tmp = x + 1
    tmp * 2         // last expression is the block value
}
```

### Return / Break / Continue

```zenscript
return value
return
break
continue
```

---

## Operators

| Category   | Operators                   |
|------------|-----------------------------|
| Arithmetic | `+` `-` `*` `/` `%`         |
| Comparison | `==` `!=` `<` `>` `<=` `>=` |
| Logical    | `&&` `\|\|` `!`             |

---

## Arrays

```zenscript
let arr = [1, 2, 3]
let v = arr[0]
arr[1] = 99
```

Array type is written as `number[]`. Index access supports chaining: `arr[i][j]`.

---

## Pointers

```zenscript
let x = 42
let p = ptr(x)
let y = deref(p)

let mem = alloc(4096)
free(mem, 4096)
```

Pointer type is written as `Pointer<T>`. `ptr`, `deref`, `alloc`, and `free` are built-in operations.

---

## Imports and Exports

```zenscript
import { getTen, x as alias } from "./lib.zs"
export { helper }

export fn helper(): number = 1
export struct Point { x: number, y: number }
export enum Option<T> { Some(T), None }
```

- `import` supports named imports and `as` aliasing.
- `export` can be applied directly to declarations or used as a grouped statement.

---

## Modifiers Summary

| Modifier   | Applies to                | Meaning                       |
|------------|---------------------------|-------------------------------|
| `let`      | variable                  | mutable binding               |
| `const`    | variable                  | immutable binding             |
| `external` | function                  | implemented outside ZenScript |
| `export`   | any top-level declaration | visible to other modules      |

---

## Known Limitations (current version)

- **LLVM codegen is disabled** — the pipeline produces IR but does not emit machine code.
- **Type inference is partial** — complex expressions may fall back to `unknown`.
- **No standard library** — only `external` functions provided by the host.
- **No error handling syntax** — no `try`/`catch` or result-propagation operators.
- **No null safety** — no `null` type or optional chaining syntax.
- **No closures or first-class functions** — functions are not values.
