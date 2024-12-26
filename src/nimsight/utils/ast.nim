## Utils for working with the Nim AST
import "$nim"/compiler/[ast, idents, lineinfos, renderer]
import ../types

import std/[strformat, options]

proc nameNode*(x: PNode): PNode =
  ## Returns the node that stores the name
  case x.kind
  of nkIdent:
    x
  of nkPostFix:
    x[1].nameNode
  of nkProcDef, nkFuncDef, nkMethodDef, nkMacroDef, nkTypeDef, nkAccQuoted, nkIdentDefs:
    x[namePos].nameNode
  else:
    raise (ref ValueError)(msg: fmt"Can't find name for {x.kind}")

func initPos*(x: TLineInfo): Position {.inline.} =
  ## Converts Nim [TLineInfo] into LSP [Position]
  initPos(uint x.line, uint x.col + 1)

proc name*(x: PNode): string =
  ## Returns the name of a node.
  # TODO: Handle unpacking postfix etc
  return x.nameNode.ident.s

proc findNode*(p: PNode, line, col: uint, careAbout: FileIndex): Option[PNode] =
  ## Finds the node at (line, col)
  # TODO: Do we need file index? Not like we can parse across files atm
  let info = p.info
  if info.line == line and info.col.uint == col and info.fileIndex == careAbout:
    result = some p

  for child in p:
    let res = findNode(child, line, col, careAbout)
    if res.isSome():
      return res


func lineCol*(x: TLineInfo): string =
  fmt"{x.line}:{x.col}"

proc ident(x: string): PIdent =
  PIdent(s: x)

proc newIdentNode*(x: string): PNode =
  ## Creates a PNode ident node
  result = newNode(nkIdent)
  result.ident = ident x

proc postfix*(x, operator: PNode): PNode =
  ## Wraps a node in a postfix
  result = newNode(nkPostFix)
  result &= operator
  result &= x
