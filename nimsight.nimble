# Package

version       = "0.1.0"
author        = "Jake Leahy"
description   = "Yet another LSP for Nim"
license       = "MIT"
srcDir        = "src"
bin = @["nimsight"]


# Dependencies

requires "nim >= 2.1.99"
requires "threading#c69e13a"
requires "https://github.com/status-im/nim-minilru#c353041"
