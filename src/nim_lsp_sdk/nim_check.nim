## Utils for working with Nim check
import std/[osproc, strformat, logging, strscans, strutils, options]
import types

import "$nim"/compiler/[parser, ast, idents, options, msgs, pathutils, syntaxes, lineinfos]

let ourOptions = "--hint:Conf:off --hint:SuccessX:off --processing:off --errorMax:0 --unitSep:on --colors:off"

proc ignoreErrors(conf: ConfigRef; info: TLineInfo; msg: TMsgKind; arg: string) =
  # TODO: Don't ignore errors
  discard


proc parseFile*(x: DocumentUri): (FileIndex, PNode) =
  ## Parses a document. This is only lexcial and is done
  ## to get start/end ranges for errors.
  var conf = newConfigRef()
  let fileIdx = fileInfoIdx(conf, AbsoluteFile x)
  var p: Parser
  if setupParser(p, fileIdx, newIdentCache(), conf):
    p.lex.errorHandler = ignoreErrors
    result = (fileIdx, parseAll(p))
    closeParser(p)
  else:
    raise (ref CatchableError)(msg: "Failed to setup parser")

proc initPos(x: TLineInfo): Position =
  return Position(line: uint x.line - 1, character: uint x.col)

proc initPos(line: SomeInteger, col: SomeInteger): Position =
  ## Creates a position from a line/col that is 1 indexed
  return Position(line: uint line - 1, character: uint col - 1)

proc findNode(p: PNode, line, col: uint, careAbout: FileIndex): Option[Range] =
  ## Finds the node at (line, col) and returns the range that corresponds to it
  let info = p.info
  if info.line == line and info.col.uint == col and info.fileIndex == careAbout:
    return some(Range(
      start: initPos(info),
      `end`: initPos(p.endInfo)
    ))
  for child in p:
    let res = findNode(child, line, col, careAbout)
    if res.isSome():
      return res

type
  SymbolUsage* = object
    ## Information storing symbol usage
    def*: (string, Position)
    usages*: seq[(string, Position)]

proc findUsages*(file: string, pos: Position): Option[SymbolUsage] =
  ## Uses --defusages to find symbol usage/defintion
  ## Uses IC so isn't braindead slow which is cool, but zero clue
  ## what stability is like lol
  # Use refc to get around https://github.com/nim-lang/Nim/issues/22205
  let (outp, status) = execCmdEx(fmt"nim check --ic:on --mm:refc {ourOptions} --defusages:{file},{pos.line + 1},{pos.character + 1} {file}")
  echo outp
  if status == QuitFailure: return
  debug(outp)
  var s = SymbolUsage()
  for lineStr in outp.splitLines():
    var
      file: string
      line: int
      col: int
    # TODO: Fix navigator.nim so that the RHS of identDefs isn't considered a decl
    if lineStr.scanf("def$s$+($i, $i)", file, line, col):
      s.def = (file, initPos(line, col))
    elif lineStr.scanf("usage$s$+($i, $i)", file, line, col):
      s.usages &= (file, initPos(line, col))
  return some s

proc getErrors*(x: DocumentUri): seq[Diagnostic] =
  ## Returns everything returned by nim check as diagnostics
  debug(fmt"Checking {x}: nim check {ourOptions} {x}")
  let (outp, statusCode) = execCmdEx(fmt"nim check {ourOptions} {x}")
  let (fIdx, root) = parseFile(x)
  debug(outp, statusCode)
  echo outp
  for error in outp.split('\31'):
    echo error
    for line in error.splitLines():
      let (ok, file, line, col, lvl, msg) = line.scanTuple("$+($i, $i) $+: $+")
      let sev = case lvl
                of "Hint": some DiagnosticSeverity.Hint
                of "Warning": some DiagnosticSeverity.Warning
                of "Error": some DiagnosticSeverity.Error
                else: none(DiagnosticSeverity)
      if file != x: continue
      if ok:
        let range = root.findNode(uint line, uint col - 1, fIdx)
        if range.isNone(): continue
        result &= Diagnostic(
          range: range.unsafeGet(),
          severity: sev,
          message: msg
        )


when isMainModule:
  echo findUsages("/home/jake/Documents/projects/nim-lsp-sdk/tests/test1.nim", initPos(13, 1))
