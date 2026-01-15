# Package

version       = "0.2.1"
author        = "Jake Leahy"
description   = "Yet another LSP for Nim"
license       = "MIT"
srcDir        = "src"
bin = @["nimsight"]


# Dependencies

requires "nim >= 2.2.4"
requires "anano ^= 0.2.1"
requires "threading#c5a39a0"
requires "gh:status-im/nim-minilru#c353041"
requires "gh:ire4ever1190/jaysonrpc#0f1f4fc"
requires "gh:ire4ever1190/nort#61c8cda"
