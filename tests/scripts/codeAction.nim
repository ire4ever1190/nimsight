#> :w
#> :wait textDocument/publishDiagnostics

proc bamboo() = discard

bambo() #[
  ^ :CodeAction ]#

#> :wait TextChanged
