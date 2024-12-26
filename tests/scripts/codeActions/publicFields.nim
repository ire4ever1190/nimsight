#> :w
#> :wait textDocument/publishDiagnostics
type
  Foo #[
  ^ :CodeAction ]# = object
    x: string
    y: proc (x: string)
    case test: bool
    of false:
      l: int
    of true:
      smth: bool
#> :wait TextChanged
