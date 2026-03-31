export struct List<T> {
  data: Pointer<T>,
  len: number,
  cap: number,
}

export fn list_new<T>(elem_size: number): List<T> {
  let cap = 8
  return List<T> { data: alloc(cap * elem_size), len: 0, cap: cap }
}

export fn list_push<T>(list: List<T>, val: T, elem_size: number): List<T> {
  if (list.len >= list.cap) {
    list = list_grow<T>(list, elem_size)
  }
  let d = list.data
  d[list.len] = val
  return List<T> { data: list.data, len: list.len + 1, cap: list.cap }
}

export fn list_get<T>(list: List<T>, i: number): T {
  let d = list.data
  return d[i]
}

export fn list_set<T>(list: List<T>, i: number, val: T): void {
  let d = list.data
  d[i] = val
}

export fn list_grow<T>(list: List<T>, elem_size: number): List<T> {
  let new_cap = list.cap * 2
  let new_data = alloc(new_cap * elem_size)
  for (let i = 0; i < list.len * elem_size; i = i + 1) {
    new_data[i] = list.data[i]
  }
  free(list.data, list.cap * elem_size)
  return List<T> { data: new_data, len: list.len, cap: new_cap }
}

export fn list_free<T>(list: List<T>, elem_size: number): void {
  free(list.data, list.cap * elem_size)
}
