import { Option } from "../stdlib/Option.zs"

let x = Option.Some(42)
let y: Option<number> = Option.None

let r1 = match x {
  Option.Some(v) -> v + 1,
  Option.None -> 0
}

enum Result<T, E> {
  Ok(T),
  Err(E)
}

let ok: Result<number, number> = Result.Ok(100)
let err: Result<number, number> = Result.Err(1)
