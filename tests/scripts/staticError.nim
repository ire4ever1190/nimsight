#> :wait textDocument/publishDiagnostics

static:
  raise (ref Exception)(msg: "hello") #[
  ^ :Diag ]#
