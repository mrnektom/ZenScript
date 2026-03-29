let s = "hello"
print_number(char_at(s, 0))

if (str_eq("abc", "abc")) print_number(1)
if (!str_eq("abc", "xyz")) print_number(2)

let s2 = str_concat("hello", " world")
print(s2)

let sub = substr("hello world", 6, 5)
print(sub)
