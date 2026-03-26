external fn print(msg: string): void
external fn print_number(n: number): void

fn get_ten(): number = 10

fn check(a: number): number {
  return if (a == 10) 1 else 0
}

let a = get_ten()
const d = print_number(check(a))
