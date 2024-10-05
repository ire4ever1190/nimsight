## Utils for working with Nim check
import std/[osproc, strformat, logging, strscans, strutils, options, sugar, jsonutils, os, streams]
import types, hooks, server

import "$nim"/compiler/[parser, ast, idents, options, msgs, pathutils, syntaxes, lineinfos]

const ourOptions = @["--hint:Conf:off", "--hint:SuccessX:off", "--processing:off", "--errorMax:0", "--unitSep:on", "--colors:off"]



# proc makeCheckOptions(file: string): string =
  # result = ourOptions
  # TODO: Nimble files don't have system/nimscript included by default, include it
  # if file.

type
  ErrorKind* = enum
    Any
      ## Fallback for when we cant parse the error.
      ## We just display the full message for this
      ## TypeMisMatch
      ## Type mismatch when calling a proc
    Unknown
      ## Unknown symbol
    AmbigiousIdentifier
      ## Trying to use an identifer when it could come from multiple modules
    # TODO: case statement missing cases, deprecated/unused

  ParsedError* = object
    ## Error message put into a structure that I can more easily display
    ## Wish the compiler had a structured errors mode
    name*: string
      ## The name given in the first line
    case kind*: ErrorKind
    of Any:
      fullText*: string
    # of TypeMisMatch:
      # args: seq[string]
        ## The args that its getting called with
    of Unknown, AmbigiousIdentifier:
      possibleSymbols*: seq[string]

func `$`(e: ParsedError): string =
  result &= e.name & "\n"
  case e.kind
  of Any:
    result &= e.fullText
  of Unknown, AmbigiousIdentifier:
    result &= "Did you mean?\n"
    for possible in e.possibleSymbols:
      result &= &"- {possible}\n"
    result.setLen(result.len - 1)

proc ignoreErrors(conf: ConfigRef; info: TLineInfo; msg: TMsgKind; arg: string) =
  # TODO: Don't ignore errors
  discard


proc parseFile*(x: DocumentUri): (FileIndex, PNode) {.gcsafe.} =
  ## Parses a document. This is only lexcial and is done
  ## to get start/end ranges for errors.
  var conf = newConfigRef()
  let fileIdx = fileInfoIdx(conf, AbsoluteFile x)
  var p: Parser
  {.gcsafe.}:
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

proc execProcess(handle: RequestHandle, cmd: string, args: openArray[string]): tuple[output: string, code: int] =
  ## Runs a process, automatically checks if the request has ended and then stops the running process.
  let process = startProcess(cmd, args=args, options = {poUsePath, poStdErrToStdOut})
  defer: process.close()
  while process.running and handle.isRunning:
    # Don't want to burn the thread with the isRunning check
    sleep 10
  if not handle.isRunning():
    # TODO: Let the caller handle it, for now we play it simple
    raise (ref ServerError)(code: RequestCancelled)
  return (process.outputStream().readAll(), process.peekExitCode())

proc findUsages*(handle: RequestHandle, file: string, pos: Position): Option[SymbolUsage] =
  ## Uses --defusages to find symbol usage/defintion
  ## Uses IC so isn't braindead slow which is cool, but zero clue
  ## what stability is like lol
  # Use refc to get around https://github.com/nim-lang/Nim/issues/22205
  let (outp, status) = handle.execProcess("nim", @["check", "--ic:on", "--mm:refc", fmt"--defusages:{file},{pos.line + 1},{pos.character + 1}"] & ourOptions & file)
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


proc getErrors*(handle: RequestHandle, x: DocumentUri): seq[Diagnostic] {.gcsafe.} =
  ## Returns everything returned by nim check as diagnostics
  debug(fmt"Checking {x}: nim check {ourOptions} {x}")
  let (outp, statusCode) = handle.execProcess("nim", @["check"] & ourOptions & x)
  let (fIdx, root) = parseFile(x)
  debug(outp, statusCode)
  echo outp
  for error in outp.split('\31'):
    echo error
    let lines = error.splitLines()
    for i in 0..<lines.len:
      let (ok, file, line, col, lvl, msg) = lines[i].scanTuple("$+($i, $i) $+: $+")
      let sev = case lvl
                of "Hint": some DiagnosticSeverity.Hint
                of "Warning": some DiagnosticSeverity.Warning
                of "Error": some DiagnosticSeverity.Error
                else: none(DiagnosticSeverity)
      if file != x: continue
      if ok:
        let range = root.findNode(uint line, uint col - 1, fIdx)
        # Couldn't match it to a node, so don't trust sending the error out.
        # Need to have some system, since macros could give an error anywhere and
        # we do want to show it
        if range.isNone(): continue
        var err: ParsedError
        # See if we can parse some more data from the error message
        if msg.startsWith("undeclared identifier"):
          let possible = collect:
            for j in i + 1 ..< lines.len:
              let (ok, _, _, name) = lines[j].scanTuple(" ($i, $i): '$+'")
              if ok:
                name
          err = ParsedError(kind: Unknown, possibleSymbols: possible)
        elif msg.startsWith("ambiguous identifier"):
          let possible = collect:
            for j in i + 1 ..< lines.len:
              let (ok, module, sym) = lines[j].scanTuple("$s$+: $+")
              if ok:
                fmt"{module}: `{sym}`"
          err = ParsedError(kind: AmbigiousIdentifier, possibleSymbols: possible)
        else:
          var fullText: string
          for j in i + 1 ..< lines.len:
            fullText &= lines[j] & '\n'
          if fullText.len > 0:
            fullText.setLen(fullText.len - 1)
          err = ParsedError(kind: Any, fullText: fullText)
        # And add the diagnotic
        err.name = msg
        result &= Diagnostic(
          range: range.unsafeGet(),
          severity: sev,
          message: $err,
          data: some err.toJson()
        )


when isMainModule:
  echo findUsages("/home/jake/Documents/projects/nim-lsp-sdk/tests/test1.nim", initPos(13, 1))
