struct Point { x: number, y: number }

struct Pair<T, U> { first: T, second: U }

let p = Point { x: 10, y: 20 }
let val = p.x

let px = ptr(val)
let v = deref(px)

let greeting = "hello"
print(greeting)
