export { String } from "./string.zs"

export fn print(s: String): void {
  __syscall3(1, 1, s.data, s.len)
  __syscall3(1, 1, "\n".data, 1)
}

export fn print_number(n: number): void {
  let buf = ['\0'; 20]
  let pos = 19
  let is_neg = 0
  let val = n

  if (n < 0) {
    is_neg = 1
    val = 0 - n
  }

  if (val == 0) {
    buf[pos] = 48
    pos = pos - 1
  }

  while (val > 0) {
    let digit = val % 10
    buf[pos] = digit + 48
    pos = pos - 1
    val = val / 10
  }

  if (is_neg == 1) {
    buf[pos] = 45
    pos = pos - 1
  }

  let start = pos + 1
  let len = 20 - start
  __syscall3(1, 1, ptr(buf) + start, len)
  __syscall3(1, 1, "\n".data, 1)
}

export fn print(n: number): void = print_number(n)

export fn alloc(size: long): long {
  return __syscall6(9, 0, size, 3, 34, -1, 0)
}

export fn free(addr: long, size: long): void {
  __syscall2(11, addr, size)
}

export fn read_line(): String {
  let buf = ['\0'; 1024]
  let bytes = __syscall3(0, 0, ptr(buf), 1024)
  if (bytes > 0) {
    if (buf[bytes - 1] == 10) {
      bytes = bytes - 1
    }
  }
  return String { len: bytes, data: ptr(buf) }
}

export fn char_at(s: String, i: number): char = s.data[i]

export fn str_eq(a: String, b: String): boolean {
  if (a.len != b.len) return false
  for (let i = 0; i < a.len; i = i + 1) {
    if (char_at(a, i) != char_at(b, i)) return false
  }
  return true
}

export fn str_concat(a: String, b: String): String {
  let total = a.len + b.len
  let buf = alloc(total)
  for (let i = 0; i < a.len; i = i + 1) {
    buf[i] = char_at(a, i)
  }
  for (let i = 0; i < b.len; i = i + 1) {
    buf[a.len + i] = char_at(b, i)
  }
  return String { len: total, data: buf }
}

export fn substr(s: String, start: number, length: number): String {
  let buf = alloc(length)
  for (let i = 0; i < length; i = i + 1) {
    buf[i] = char_at(s, start + i)
  }
  return String { len: length, data: buf }
}
