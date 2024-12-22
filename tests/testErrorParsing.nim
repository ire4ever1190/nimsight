## Tests for parsing error messages

import std/[unittest, osproc, os, strformat, strutils, sequtils]

import nim_lsp_sdk/[errors {.all.}, customast]

let
  auxFile = currentSourcePath().parentDir() / "errorParsingAuxFile.nim"
  (output, _) = execCmdEx(fmt"{getCurrentCompilerExe()} check --unitsep:on --hint:SuccessX:off --colors:off --hint:Conf:off --processing:off {auxFile}")

# Quick smoke test
test "Errors are parsed without issue":
  for msg in output.msgChunks():
    discard msg.strip().parseError()

suite "Undeclared identifiers":
  test "Possible choices":
    let msg = """
file.nim(16, 6) Error: undeclared identifier: 'worl'
candidates (edit distance, scope distance); see '--spellSuggest':
 (1, 1): 'world'
"""
    let err = msg.parseError()
    check err.location.file == "file.nim"
    check err.location.line == 16
    check err.location.col == 6
    check err.msg == "Undeclared identifier: 'worl'"
    check err.possibleSymbols == @["world"]

  test "Nothing possible":
    let msg = "file.nim(17, 6) Error: undeclared identifier: 'p'"
    let err = msg.parseError()
    check err.kind == Any

test "Template instantiations":
  let msg = """
file.nim(3, 4) template/generic instantiation of `foo` from here
file.nim(2, 10) Error: test"""
  let err = msg.parseError()
  check err.msg == "test"
  check err.location == NimLocation(file: "file.nim", line: 2, col: 10)
  check err.relatedInfo == @[
    RelatedInfo(
      location: NimLocation(file: "file.nim", line: 3, col: 4),
      msg: "template/generic instantiation of `foo` from here"
    )
  ]

test "Error with square brackets":
  # Tests an issue that occured where square brackets were parsed as belonging to the inbuilt name
  let msg = """
public.nim(39, 15) template/generic instantiation of `collect` from here
public.nim(41, 44) Error: type mismatch
Expression: postfix(ast[ident], newIdentNode("*"))
  [1] ast[ident]: Node
  [2] newIdentNode("*"): PNode

Expected one of (first mismatch at [position]):
[1] proc postfix(x, operator: PNode): PNode"""
  let err = msg.parseError()
  check err.msg == """
type mismatch
Expression: postfix(ast[ident], newIdentNode("*"))
  [1] ast[ident]: Node
  [2] newIdentNode("*"): PNode

Expected one of (first mismatch at [position]):
[1] proc postfix(x, operator: PNode): PNode"""
