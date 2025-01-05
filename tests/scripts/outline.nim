#> :w
#> :Symbols

proc bar(x: string) = discard

type
  Person = object
    name, age: string
    alive: bool
    handler: proc (a: int)
  Foo = enum
    A
    B
    C, D
    E = 8
  Equalable = concept
    proc `==`(a, b: Self)

let
  someLet = 1
  anotherLet = 2
const someConst = "hello"

block:
  let insideBlock = 9

#> :wait textDocument/documentSymbol
