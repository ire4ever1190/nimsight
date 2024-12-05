## Utils for working with the Nim AST
import "$nim"/compiler/[parser, ast, idents, options, msgs, pathutils, syntaxes, lineinfos, llstream, renderer]
import ../types

import std/strformat

type ParsedFile* = tuple[idx: FileIndex, ast: PNode]

proc ignoreErrors(conf: ConfigRef; info: TLineInfo; msg: TMsgKind; arg: string) =
  # TODO: Don't ignore errors
  discard

proc parseFile*(x: DocumentUri, content: sink string): ParsedFile {.gcsafe.} =
  ## Parses a document. Doesn't perform any semantic analysis
  var conf = newConfigRef()
  let fileIdx = fileInfoIdx(conf, AbsoluteFile x)
  var p: Parser
  {.gcsafe.}:
    parser.openParser(p, fileIdx, llStreamOpen(content), newIdentCache(), conf)
    defer: closeParser(p)
    p.lex.errorHandler = ignoreErrors
    result = (fileIdx, parseAll(p))

proc nameNode(x: PNode): PNode =
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

func initPos*(x: TLineInfo): Position =
  ## Converts Nim [TLineInfo] into LSP [Position]
  initPos(uint x.line, uint x.col + 1)

proc name(x: PNode): string =
  ## Returns the name of a node.
  # TODO: Handle unpacking postfix etc
  return x.nameNode.ident.s

func initRange(p: PNode): Range =
  ## Creates a range from a node
  result = Range(start: p.info.initPos(), `end`: p.endInfo.initPos())
  if result.`end` < result.start:
    # The parser fails to set this correctly in a few spots.
    # Attempt to make it usable
    case p.kind
    of nkIdent:
      result.`end`.line = result.start.line
      result.`end`.character = result.start.character + p.name.len.uint
    else:
      result.`end` = result.start


proc ident(x: string): PIdent =
  PIdent(s: x)

proc newIdentNode*(x: string): PNode =
  ## Creates a PNode ident node
  result = newNode(nkIdent)
  result.ident = ident x

proc editWith*(original: PNode, update: PNode): TextEdit =
  ## Creates an edit that will replace `original` with `update`.
  TextEdit(range: original.initRange, newText: update.renderTree({renderNonExportedFields}))
