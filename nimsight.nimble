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
requires "gh:status-im/nim-minilru#6dd93fe"
requires "gh:ire4ever1190/jaysonrpc >= 0.5.1"
requires "gh:ire4ever1190/nort >= 0.5.0"
requires "gh:ire4ever1190/legit >= 0.1.1"
