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

print(result)
