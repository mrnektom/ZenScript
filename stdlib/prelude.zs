export fn print(s: string): void {
  __syscall3(1, 1, __ptr_to_int(s), __str_len(s))
  __syscall3(1, 1, __ptr_to_int("\n"), 1)
}

export fn print_number(n: number): void = __print_number(n)
export fn read_line(): string = __read_line()
