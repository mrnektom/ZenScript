export { String } from "./string.zs"

export fn print(s: String): void {
  __syscall3(1, 1, __ptr_to_int(s), __str_len(s))
  __syscall3(1, 1, __ptr_to_int("\n"), 1)
}

export fn print_number(n: number): void {
  let buf_base = __alloc_buf(20)
  let pos = 19
  let is_neg = 0
  let val = n

  if (n < 0) {
    is_neg = 1
    val = 0 - n
  }

  if (val == 0) {
    __write_byte(buf_base + pos, 48)
    pos = pos - 1
  }

  while (val > 0) {
    let digit = val % 10
    __write_byte(buf_base + pos, digit + 48)
    pos = pos - 1
    val = val / 10
  }

  if (is_neg == 1) {
    __write_byte(buf_base + pos, 45)
    pos = pos - 1
  }

  let start = pos + 1
  let len = 20 - start
  __syscall3(1, 1, buf_base + start, len)
  __syscall3(1, 1, __ptr_to_int("\n"), 1)
}

export fn print(n: number): void = print_number(n)
export fn read_line(): String = __read_line()