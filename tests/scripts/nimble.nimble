# Package
#> :wait textDocument/publishDiagnostics

version       = "0.1.0" #[
   ^ :Diag ]#
author        = "Jake Leahy"
description   = "SDK for creating LSP servers"
license       = "MIT"
srcDir        = "src"
bin = @["nim_lsp_sdk"]


# Dependencies

requires "nim >= 2.1.99"
requires "threading#c69e13a"
requires "https://github.com/status-im/nim-minilru#c353041"
requires "anano >= 0.2.0 & < 0.3.0"
