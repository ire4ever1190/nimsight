#> :w
#> :wait textDocument/publishDiagnostics

discard "hello" * "world" #[
          ^ :Diag ]#

proc `<-`(a: var int, b: int) = a = b

var foo: int
foo <- "string" #[
        ^ :Diag ]#
