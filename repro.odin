package shit

Foo :: struct { a: u16, b: u8 } // note: there is 1 byte of padding
Bar :: struct { a: u16, b: u8, c: u8 }

@export do_bar :: proc(b: Bar) -> u8 {
    return b.b + b.c
}

@export do_foo :: proc(f: Foo) -> u8 {
    return f.b
}

@export do_foo2 :: proc(f: Foo) -> u8 {
    return f.b + u8(f.a)
}

@export do_bar2 :: proc(f: Bar) -> u8 {
    return f.c
}