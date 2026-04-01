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
| `Unit`       | singleton unit type         |
| `T[]`        | array of T                  |
| `Pointer<T>` | pointer to T                |
| `SomeName`   | user-defined struct or enum |
| `Generic<T>` | instantiated generic type   |

### Scalar type declarations

Scalar (primitive) types are declared in stdlib using the `scalar` keyword:

```zs
scalar number
scalar long
```

Valid scalar names: `number`, `long`, `short`, `byte`, `boolean`, `char`. Declaring an unknown name is a compile error.
`stdlib/prelude.zs` declares all built-in scalar types, making them available in every module.

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

## Extension Functions

Extension functions add methods to existing types without modifying the original type definition.

```zenscript
fn number.double(): number = this * 2

fn number.clamp(min: number, max: number): number =
    if (this < min) min else if (this > max) max else this

fn string.isEmpty(): boolean = this.length == 0

fn Point.translate(dx: number, dy: number): Point =
    Point { x: this.x + dx, y: this.y + dy }

fn Point.distanceSq(other: Point): number = {
    let dx = this.x - other.x
    let dy = this.y - other.y
    dx * dx + dy * dy
}
```

### Generic extensions

```zenscript
fn Option<T>.getOrElse(default: T): T = match this {
    Option.Some(v) -> v,
    Option.None    -> default
}

fn Result<T, E>.isOk(): boolean = match this {
    Result.Ok(_)  -> true,
    Result.Err(_) -> false
}
```

### Call syntax

```zenscript
let n = 5
let d = n.double()               // 10
let c = n.clamp(0, 3)            // 3

let p = Point { x: 1, y: 2 }
let q = p.translate(3, 4)        // Point { x: 4, y: 6 }

let opt = Option.Some(42)
let v = opt.getOrElse(0)         // 42
```

- The receiver is the expression to the left of the dot; inside the body it is `this`.
- `expr.method(args)` is equivalent to calling `ReceiverType.method(expr, args)`.
- Extensions may be defined on any type: built-in scalars (`number`, `string`, `boolean`, `char`, `long`, `short`,
  `byte`), structs, enums, arrays, and generic instantiations.
- Dispatch is **static** — the extension to call is resolved at compile time based on the receiver's static type.
- `export` is supported: `export fn Point.translate(...)`.
- Overloading rules apply — the same extension name can be defined with different signatures on the same receiver type.
- Extensions do not have access to any private state beyond what is available through normal field access.

---

## Lambdas and Closures

Lambda expressions create anonymous function values.

```zenscript
let greet  = { -> "hello" }                         // no parameters
let double = { x -> x * 2 }                         // one param, type inferred
let add    = { a: number, b: number -> a + b }       // explicit types

// Block body — last expression is the return value
let compute = { x: number ->
    let tmp = x * x
    tmp + 1
}
```

### Trailing lambda

When the last argument of a call is a lambda it can be placed outside the parentheses:

```zenscript
list.map { x -> x * 2 }
list.filter { x -> x > 0 }
list.fold(0) { acc, x -> acc + x }
```

### Closures

Lambdas capture variables from the enclosing scope **by reference** — mutations are visible on both sides of the closure
boundary:

```zenscript
let count = 0
let inc   = { -> count = count + 1 }

inc()
inc()
// count == 2
```

### Invocation

A stored function value is called with the same syntax as a named function:

```zenscript
let result = add(3, 4)   // 7
```

---

## Functional Types

Function types are written as `(ParamType, ...) -> ReturnType`.

```zenscript
let f:      (number) -> number  = { x -> x * 2 }
let pred:   (number) -> boolean = { x -> x > 0 }
let action: () -> void          = { -> print(42) }
```

Function types are first-class — they can appear anywhere a type is expected: variable annotations, parameters, and
return types.

### Higher-order functions

```zenscript
fn apply(f: (number) -> number, x: number): number = f(x)

fn makeAdder(n: number): (number) -> number = { x -> x + n }

let addFive = makeAdder(5)
let result  = addFive(3)    // 8
```

### Type aliases

`type` declares an alias for any type expression.

```zenscript
type Predicate<T>    = (T) -> boolean
type Transform<A, B> = (A) -> B
type Action          = () -> void
```

Aliases are purely structural — `Predicate<number>` and `(number) -> boolean` are interchangeable. `export type` exports
an alias to other modules.

```zenscript
fn filter<T>(arr: T[], pred: Predicate<T>): T[] = ...

export type Callback = (string) -> void
```

---

## Safe Navigation (`?.` Operator)

`?.` is syntactic sugar for calling `.map { v -> ... }` on an `Option<T>` value. It applies a field access, method call,
or extension call to the wrapped value only if it is `Some`, and propagates `None` otherwise.

### Syntax and desugaring

```zenscript
opt?.field          // opt.map { v -> v.field }
opt?.method(args)   // opt.map { v -> v.method(args) }
opt?.ext(args)      // opt.map { v -> v.ext(args) }   (extension functions included)
```

The result type is always `Option<T>` where `T` is the type of the accessed field or the return type of the called
function.

### Examples

```zenscript
struct Address { city: string }
struct User    { name: string, address: Option<Address> }

let user: Option<User> = Option.Some(User { name: "Alice", address: Option.Some(Address { city: "NY" }) })

let name: Option<string> = user?.name          // Option.Some("Alice")
let city: Option<string> = user?.address?.city // Option.Some("NY")
```

Field access via regular `.` and safe access via `?.` can be mixed in the same chain:

```zenscript
// address is Option<Address>, city is a plain string field on Address
let city = user?.address?.city   // Option<string>
```

### Extension calls

```zenscript
fn string.upper(): string = ...

let name: Option<string> = Option.Some("alice")
let up: Option<string>   = name?.upper()   // Option.Some("ALICE")
```

### Chaining

`?.` is left-associative. Each step receives the `Option` produced by the previous step:

```zenscript
// a: Option<A>,  b: B field on A,  c: C field on B
let val: Option<C> = a?.b?.c
// equivalent to: a.map { v -> v.b }.map { v -> v.c }
```

### Unwrapping the result

Combine with `getOrElse` (an extension on `Option<T>`) to extract a default value:

```zenscript
let city: string = user?.address?.city.getOrElse("unknown")
```

### Constraints

- The receiver of `?.` must be `Option<T>`; applying it to any other type is a compile error.
- `?.` has lower precedence than `.`: `a.b?.c` means `(a.b)?.c`.

---

## `!!` Operator (Error Propagation)

`!!` is a postfix operator for propagating errors out of the current function. It calls `.toEither()` on its operand and
either returns early (on `Left`) or unwraps the value (on `Right`).

### Desugaring

```zenscript
expr!!
// expands to:
match expr.toEither() {
    Either.Left(e)  -> return e,
    Either.Right(v) -> v
}
```

The type of the whole `expr!!` expression is `Right`.

### Type constraints

- `expr.toEither()` must return `Either<L, R>`.
- `L` must exactly match the declared return type of the enclosing function.
- `!!` may only appear inside a function body.

### Usage with `Either` directly

```zenscript
fn divide(a: number, b: number): string =
    if (b == 0) Either.Left("division by zero") else Either.Right(a / b)

fn compute(): string {
    let result: number = divide(10, 2)!!   // returns "division by zero" if Left
    result * 3                              // reached only when Right
}
```

`Either<L, R>.toEither()` is the identity — applying `!!` to an `Either` value directly is valid.

### Usage with `Option`

`Option<T>` has a stdlib extension `fn Option<T>.toEither(): Either<Unit, T>`:

- `Option.None` → `Either.Left(Unit)`
- `Option.Some(v)` → `Either.Right(v)`

```zenscript
fn findUser(id: number): Option<string> = ...

fn greet(): Unit {
    let name: string = findUser(42)!!   // returns Unit when None
    print(name)
}
```

### User-defined `toEither()`

Any type can participate in `!!` by defining a `toEither()` extension:

```zenscript
enum ParseError { InvalidInput, Overflow }
struct ParseResult { value: number, error: Option<ParseError> }

fn ParseResult.toEither(): Either<ParseError, number> =
    match this.error {
        Option.Some(e) -> Either.Left(e),
        Option.None    -> Either.Right(this.value)
    }

fn run(): ParseError {
    let n: number = parseNumber("42")!!   // propagates ParseError on failure
    print(n)
}
```

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

| Category          | Operators                                                       |
|-------------------|-----------------------------------------------------------------|
| Arithmetic        | `+` `-` `*` `/` `%`                                             |
| Comparison        | `==` `!=` `<` `>` `<=` `>=`                                     |
| Logical           | `&&` `\|\|` `!`                                                 |
| Error propagation | `!!` (postfix, see [!! Operator](#-operator-error-propagation)) |

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

## Standard Library

The standard library (`stdlib/`) is automatically available in every module via the prelude.

### `Option<T>`

```zenscript
enum Option<T> { Some(T), None }
```

| Extension   | Signature                                     | Description                                   |
|-------------|-----------------------------------------------|-----------------------------------------------|
| `getOrElse` | `fn Option<T>.getOrElse(default: T): T`       | Returns the wrapped value or `default`        |
| `map`       | `fn Option<T>.map<U>(f: (T) -> U): Option<U>` | Applies `f` to the inner value if `Some`      |
| `toEither`  | `fn Option<T>.toEither(): Either<Unit, T>`    | `None` → `Left(Unit)`, `Some(v)` → `Right(v)` |

### `Either<Left, Right>`

```zenscript
enum Either<Left, Right> { Left(Left), Right(Right) }
```

| Extension   | Signature                                                   | Description                                         |
|-------------|-------------------------------------------------------------|-----------------------------------------------------|
| `toEither`  | `fn Either<L, R>.toEither(): Either<L, R>`                  | Identity — allows `!!` to work on `Either` directly |
| `mapRight`  | `fn Either<L, R>.mapRight<R2>(f: (R) -> R2): Either<L, R2>` | Transforms the `Right` value, passes `Left` through |
| `getOrElse` | `fn Either<L, R>.getOrElse(default: R): R`                  | Returns the `Right` value or `default`              |

### `Unit`

`Unit` is a singleton type with exactly one value, also written `Unit`. Functions that produce no meaningful result have
return type `Unit`.

---

## Modifiers Summary

| Modifier   | Applies to                                    | Meaning                                    |
|------------|-----------------------------------------------|--------------------------------------------|
| `let`      | variable                                      | mutable binding                            |
| `const`    | variable                                      | immutable binding                          |
| `external` | function                                      | implemented outside ZenScript              |
| `export`   | any top-level declaration, extension function | visible to other modules                   |
| `type`     | type alias declaration                        | names a type expression; supports generics |

---

## Known Limitations (current version)

- **LLVM codegen is disabled** — the pipeline produces IR but does not emit machine code.
- **Type inference is partial** — complex expressions may fall back to `unknown`.
- **No null safety** — no `null` type; use `Option<T>` and `?.` instead.
