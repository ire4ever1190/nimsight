#> :w
#> :wait textDocument/publishDiagnostics

proc bar(a, b: string) = discard
proc bar(a: string, c: int) = discard

bar("hello", true) #[
    ^ :Diag
             ^ :Diag ]#
