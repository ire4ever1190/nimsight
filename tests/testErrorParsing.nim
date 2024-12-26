## Tests for parsing error messages

import std/[unittest, osproc, os, strformat, strutils, sequtils]

import nimsight/[errors {.all.}, customast]

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

test "Random errors I got once":
  let msgs = """
/files/test.nim(5, 9) Error: expression expected, but found '{.'
=============
/files/test.nim(5, 41) Error: invalid indentation
=============
/files/test.nim(5, 41) Error: expression expected, but found '.}'
=============
/files/test.nim(5, 11) Error: undeclared identifier: 'hint'
candidates (edit distance, scope distance); see '--spellSuggest':
 (1, 2): 'cint'
 (1, 2): 'int'
 (1, 2): 'uint'
=============
/files/test.nim(5, 11) Error: expression 'hint' has no type (or is ambiguous)
=============
/files/test.nim(5, 16) Error: undeclared identifier: 'XDeclaredButNotUsed'
candidates (edit distance, scope distance); see '--spellSuggest':
 (9, 3): 'declaredInScope'
=============
/files/test.nim(5, 15) Error: expression '' has no type (or is ambiguous)
Error: in expression ' do:
  off': identifier expected, but found ''
=============
/files/test.nim(5, 11) Error: attempting to call undeclared routine: '<Error>'
Error: in expression ' do:
  off': identifier expected, but found ''
=============
/files/test.nim(5, 11) Error: attempting to call undeclared routine: '<Error>'
=============
/files/test.nim(5, 11) Error: expression '' cannot be called
=============
/files/test.nim(5, 11) Error: expression '' has no type (or is ambiguous)
=============
/files/test.nim(5, 5) Error: 'let' symbol requires an initialization
=============
/files/test.nim(3, 5) Hint: 'inputs' is declared but not used [XDeclaredButNotUsed]
=============
/files/test.nim(5, 5) Hint: 'x' is declared but not used [XDeclaredButNotUsed]
=============
/files/test.nim(1, 13) Warning: imported and not used: 'sugar' [UnusedImport]
=============
/files/test.nim(1, 20) Warning: imported and not used: 'tables' [UnusedImport]
""".split("=============\n")
  for msg in msgs:
    echo msg
    discard msg.parseError()
    echo "Finished"
