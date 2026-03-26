external fn print(msg: string): void
external fn print_number(n: number): void

fn print(n: number): void = print_number(n)

fn get_ten(): number = 10

fn check(a: number): number {
  return if (a == 10) 1 else 0
}

fn add(a: number, b: number): number = a
fn add(a: number): number = a

let t = true
let f = false

let a = get_ten()

a = 50

const d = print(check(a))
const e = print(add(1, 2))
const f = print(add(5))
