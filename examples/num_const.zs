external fn print(msg: string): void
external fn print_number(n: number): void

fn get_ten(): number = 10

fn check(a: number): number {
  if a == 10 { return 1 } else { return 0 }
}

let a = get_ten()
const b = print_number(a)
const c = check(a)
const d = print_number(c)
