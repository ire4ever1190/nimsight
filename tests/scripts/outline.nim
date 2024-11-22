#> :w
#> :wait textDocument/publishDiagnostics
#> :Symbols

proc bar(x: string) = discard

type
  Person = object
    name, age: string
    alive: bool
  Foo = enum
    A
    B
    C, D
    E = 1

let
  someLet = 1
  anotherLet = 2
const someConst = "hello"

#> :wait textDocument/documentSymbol
