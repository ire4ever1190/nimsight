## Utils for working with Nim check
import std/[osproc, strformat, logging, strscans, strutils, options, sugar, jsonutils, os, streams, tables]
import types, hooks, server, params

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
    range*: Range
      ## Start/end position that the error corresponds to
    severity*: DiagnosticSeverity
    file*: string
    case kind*: ErrorKind
    of Any:
      fullText*: string
    # of TypeMisMatch:
      # args: seq[string]
        ## The args that its getting called with
    of Unknown, AmbigiousIdentifier:
      possibleSymbols*: seq[string]


proc initPos(line: SomeInteger, col: SomeInteger): Position =
  ## Creates a position from a line/col that is 1 indexed
  result = Position(character: uint col - 1)
  # Handle underflows
  if line != 0:
    result.line = uint line - 1


func initPos(x: TLineInfo): Position =
  initPos(uint x.line, uint x.col + 1)

func initRange(p: PNode): Range =
  ## Creates a range from a node
  result = Range(start: p.info.initPos(), `end`: p.endInfo.initPos())

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

proc parseFile*(x: TextDocumentIdentifier): PNode =
  x.uri.replace("file://", "").parseFile()[1]


type
  State* = enum
    Any
    InObject
    InEnum
    InRoutine


proc exploreAST*[T](x: PNode, result: var seq[T],
                   handler: proc (x: PNode, state: State, result: var seq[T]),
                   state = State.Any) =
  ## Helper function to explore the AST. Keeps track of state of what context it is in
  ## Calls the handler and each node.
  handler(x, state, result)
  let newState = case x.kind
                 of nkObjectTy: InObject
                 of nkEnum: InEnum
                 of routineDefs: InRoutine
                 else: state
  for child in x:
    exploreAST(child, result, state)


func toSymbolKind(x: PNode): SymbolKind =
  ## Converts from Nim NodeKind into LSP SymbolKind
  case x.kind
  of nkEnumFieldDef:
    EnumMember
  of nkFuncDef, nkProcDef:
    Function
  of nkMethodDef:
    Method
  of nkTypeDef:
    case x[2].kind:
    of nkTypeClassTy:
      Interface
    of nkRefTy, nkObjectTy: # Not correct! nkRef could just be a type alias not an obkect
      Object
    of nkEnumTy:
      Enum
    else:
      TypeParameter
  else:
    # Likely not good enough
    Variable

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

proc name(x: PNode): string =
  ## Returns the name of a node.
  ## Handles unpacking postfix etc
  return x.nameNode.ident.s

proc toDocumentSymbol(x: PNode, kind = x.toSymbolKind()): DocumentSymbol =
  DocumentSymbol(
    name: x.name,
    kind: kind,
    range: x.initRange(),
    selectionRange: x.nameNode.initRange()
  )


# TODO: Clean up this whole process
# Maybe make a genxeric if kind: body: recurse children thing?
proc collectTypeFields(x: PNode, symbols: var seq[DocumentSymbol]) =
  if x.kind == nkIdentDefs:
    symbols &= x.toDocumentSymbol(kind=Property)
  else:
    for child in x:
      child.collectTypeFields(symbols)


proc collectDocumentSymbols(x: PNode, symbols: var seq[DocumentSymbol]) =
  ## Converts a node into a [DocumentSymbol].
  ## `isA` can be used to mark that all symbols are of a certain kind. Useful for context
  let kind = x.toSymbolKind()
  if x.kind in {nkProcDef, nkFuncDef, nkMethodDef, nkMacroDef, nkTypeDef}:
    var symbol = x.toDocumentSymbol()
    # For objects, we also want to append the children
    if kind == Enum:
      x[2].collectDocumentSymbols(symbol.children)
      for member in symbol.children:
        member.kind = EnumMember
    elif kind == Object:
      x[2].collectTypeFields(symbol.children)
    symbols &= symbol
  else:
    for child in x:
      child.collectDocumentSymbols(symbols)


proc outlineDocument*(x: PNode): seq[DocumentSymbol] =
  ## Creates an outline of symbols in the document.
  ## TODO: Check if the client supports heirarchy or not
  x.collectDocumentSymbols(result)

proc createFix*(e: ParsedError, diagnotic: Diagnostic): seq[CodeAction] =
  ## Returns possibly fixes for an error
  case e.kind
  of Unknown:
    for option in e.possibleSymbols:
      result &= CodeAction(
        title: option,
        diagnostics: some @[diagnotic],
        edit: some WorkspaceEdit(
            changes: some toTable({
              "file://" & e.file: @[TextEdit(range: e.range, newText: option)]
            })
          )
      )
  else: discard


func contains*(r: Range, p: Position): bool =
  ## Returns true if a position is within a range
  # For start/end, we need to check columns
  if p.line == r.start.line:
    return p.character >= r.start.character
  if p.line == r.`end`.line:
    return p.character <= r.`end`.character
  # For everything else we can just check that its in between
  return p.line in r.start.line .. r.`end`.line

func contains*(r: Range, p: PNode): bool =
  ## Returns true if a node is within a range
  p.info.initPos in r

proc findNode(p: PNode, line, col: uint, careAbout: FileIndex): Option[Range] =
  ## Finds the node at (line, col) and returns the range that corresponds to it
  let info = p.info
  if info.line == line and info.col.uint == col and info.fileIndex == careAbout:
    var range = p.initRange()
    # Handle cases where the end info is 0
    if range.`end` < range.start and p.kind == nkExprColonExpr:
      return some p[1].initRange()
    return some range

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
    process.kill()
    discard process.waitForExit()
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
  var s = SymbolUsage()
  debug(outp)
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

proc getErrors*(handle: RequestHandle, x: DocumentUri): seq[ParsedError] {.gcsafe.} =
  ## Parses errors from `nim check` into a more structured form
  let (outp, statusCode) = handle.execProcess("nim", @["check"] & ourOptions & x)
  let (fIdx, root) = parseFile(x)
  for error in outp.split('\31'):
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
        err.range = range.unsafeGet()
        err.severity = sev.unsafeGet()
        err.file = file
        result &= err

proc getDiagnostics*(handle: RequestHandle, x: DocumentUri): seq[Diagnostic] {.gcsafe.} =
  for err in handle.getErrors(x):
     result &= Diagnostic(
        range: err.range,
        severity: some err.severity,
        message: $err,
      )

when isMainModule:
  echo findUsages("/home/jake/Documents/projects/nim-lsp-sdk/tests/test1.nim", initPos(13, 1))
