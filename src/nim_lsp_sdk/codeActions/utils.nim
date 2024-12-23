import ../[customast, server, params]
import std/[options, logging, strutils]

import "$nim"/compiler/[lexer, llstream, pathutils, idents, options]

type
  CodeActionProvider = proc (
    handle: RequestHandle,
    params: CodeActionParams,
    ast: Tree,
    node: NodeIdx): seq[CodeAction]
    ## Code action provider can return a list of actions that can be applied to a node.
    ## `nodes` is the list of nodes that match the range specified in `params`


var providers: seq[CodeActionProvider]

proc registerProvider*(x: CodeActionProvider) =
  ## Registers a provider that will be queired by [getCodeActions].
  providers &= x

proc getCodeActions*(h: RequestHandle, params: CodeActionParams): seq[CodeAction] =
  ## Returns all code actions that apply to a code action request.
  # First find the node that action is referring to
  let root = h.parseFile(params.textDocument.uri)
  let node = root.ast[].findNode(params.range)
  if node.isNone:
    error "Could not find a node for this codeAction"
    return

  # Now run every provider, getting the list of actions
  {.gcsafe.}:
    debug "Running providers: ", len(providers)
    for provider in providers:
      result &= provider(h, params, root.ast, node.unsafeGet())

proc newLexer(content: sink string): Lexer =
  ## Creates a new lexer for `content`
  let stream = llStreamOpen(content)
  result.openLexer(AbsoluteFile"content.nim", stream, newIdentCache(), newConfigRef())

type
  Tokeniser = object
    lexer: Lexer
    spacing: string ## Whitespace between last token and current
    curr: Token


proc newTokeniser(content: sink string): Tokeniser =
  ## Creates a new lexer for `content`
  let stream = llStreamOpen(content)
  result.lexer.openLexer(AbsoluteFile"content.nim", stream, newIdentCache(), newConfigRef())

proc peek(a: Tokeniser): Token = a.curr
proc next(a: var Tokeniser): Token =
  let
    old = a.curr
    oldCol = old.col + len($old)
  a.lexer.rawGetTok(a.curr)
  if old.line == a.curr.line:
    echo a.curr.col, " ", old.col
    a.spacing = " ".repeat(a.curr.col - oldCol)
  else:
    a.spacing = "\n".repeat(a.curr.line - old.line ) & " ".repeat(a.curr.col)

  a.curr

proc atPos(a: Tokeniser, line, col: int): bool =
  a.curr.line == line and a.curr.col == col

proc getTok(l: var Lexer): Token =
  l.rawGetTok(result)

func sameToken(a, b: Token): bool =
  ## Checks that both tokens are the same
  return a.tokType == b.tokType and $a == $b and a.tokType != tkEof


proc minimiseChanges(file, newContent: string, line, col: int): string =
  ## Minimises changes by trying to place `newContent` inside `file`.
  ## Poor mans CST
  var
    oLexer = newTokeniser(file)
    uLexer = newTokeniser(newContent)

  while not oLexer.atPos(line, col) and oLexer.next().tokType != tkEof:
    discard

  while oLexer.next().sameToken(uLexer.next()):
    result &= oLexer.spacing & $oLexer.peek()

const a = """import std/
  [strutils]"""
const b = """import
  std/[strutils]"""

echo minimiseChanges(a, b, 0, 0)
