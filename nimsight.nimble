# Package

version       = "0.1.0"
author        = "Jake Leahy"
description   = "Yet another LSP for Nim"
license       = "MIT"
srcDir        = "src"
bin = @["nimsight"]


# Dependencies

requires "nim >= 2.2.4"
requires "threading#c5a39a0"
requires "https://github.com/status-im/nim-minilru#c353041"
requires "gh:ire4ever1190/jaysonrpc#75fc3ed"
