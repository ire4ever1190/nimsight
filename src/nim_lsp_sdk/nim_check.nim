## Utils for working with Nim check
import std/[osproc, strformat, logging, strscans, strutils, options, sugar, jsonutils, os, streams, tables, paths]
import types, hooks, server, params, errors

import utils/ast

import "$nim"/compiler/[parser, ast, idents, options, msgs, pathutils, syntaxes, lineinfos, llstream]


const ourOptions = @["--hint:Conf:off", "--hint:SuccessX:off", "--processing:off", "--errorMax:0", "--unitSep:on", "--colors:off"]


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
  # TODO: Handle unpacking postfix etc
  return x.nameNode.ident.s

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
  if result.`end` < result.start:
    # The parser fails to set this correctly in a few spots.
    # Attempt to make it usable
    case p.kind
    of nkIdent:
      result.`end`.line = result.start.line
      result.`end`.character = result.start.character + p.name.len.uint
    else:
      result.`end` = result.start

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

proc exploreAST*(x: PNode, filter: proc (x: PNode): bool,
                   handler: proc (x: PNode): bool) {.effectsOf: [filter, handler].}=
  ## Helper function to explore the AST
  ## - filter: proc to determine if the handler should be called
  ## - handler: proc called on each node, only recurses if it returns true
  if not filter(x) or handler(x):
    for child in x:
      exploreAST(child, filter, handler)

proc ofKind(x: set[TNodeKind]): (proc (x: PNode): bool) =
  proc (node: PNode): bool = node.kind in x

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

proc collectIdentDefs(x: PNode): seq[DocumentSymbol] =
  var res: seq[DocumentSymbol]
  x.exploreAST(ofKind({nkIdentDefs, nkConstDef})) do (node: PNode) -> bool:
    for child in node.sons[0 ..< ^2]:
      res &= child.toDocumentSymbol()
  return res

proc collectType(node: PNode): DocumentSymbol =
  ## Collects a document symbol for a type definition
  assert node.kind == nkTypeDef, "Must be a type section"

  let syms = node.toDocumentSymbol()

  syms.children &= node.collectIdentDefs()

  node.exploreAST(ofKind({nkEnumTy})) do (node: PNode) -> bool:
    node.exploreAST(ofKind({nkIdent, nkEnumFieldDef})) do (node: PNode) -> bool:
      syms.children &= (if node.kind == nkIdent: node else: node[0]).toDocumentSymbol()
  return syms

proc outlineDocument*(x: PNode): seq[DocumentSymbol] =
  ## Creates an outline of symbols in the document.
  ## TODO: Check if the client supports heirarchy or not
  var symbols = newSeq[DocumentSymbol]()
  # Explore top level decls
  for node in x:
    case node.kind
    of nkVarSection..nkConstSection:
      symbols &= node.collectIdentDefs()
    of nkProcDef..nkIteratorDef:
      symbols &= node.toDocumentSymbol()
    of nkTypeSection:
      node.exploreAST(ofKind({nkTypeDef})) do (node: PNode) -> bool:
        symbols &= node.collectType()
    else: discard
  return symbols

proc createFix*(e: ParsedError, diagnotic: Diagnostic): seq[CodeAction] =
  ## Returns possibly fixes for an error
  case e.kind
  of Unknown:
    result = newSeq[CodeAction]()
    for option in e.possibleSymbols:
      result &= CodeAction(
        title: option,
        diagnostics: some @[diagnotic],
        edit: some WorkspaceEdit(
            changes: some toTable({
              DocumentURI("file://" & e.file): @[TextEdit(range: e.range, newText: option)]
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

proc raiseCancelled() {.raises: [ServerError].} =
    raise (ref ServerError)(code: RequestCancelled)

proc execProcess(handle: RequestHandle, cmd: string, args: openArray[string], input = "", workingDir=""): tuple[output: string, code: int] =
  ## Runs a process, automatically checks if the request has ended and then stops the running process.
  # Don't start a process if the handle is already cancelled
  if not handle.isRunning(): raiseCancelled()

  let process = startProcess(
    cmd,
    args=args,
    options = {poUsePath, poStdErrToStdOut},
    workingDir=workingDir
  )
  defer: process.close()

  # mimic execCmdEx, need to close the stream so it sends EOF
  if input != "":
    process.inputStream().write(input)
  close inputStream(process)

  while process.running and handle.isRunning:
    # Don't want to burn the thread with the isRunning check
    sleep 10
  if not handle.isRunning():
    # TODO: Let the caller handle it, for now we play it simple
    process.kill()
    discard process.waitForExit()
    raiseCancelled()
  return (process.outputStream().readAll(), process.peekExitCode())

proc findUsages*(handle: RequestHandle, file: DocumentURI, pos: Position): Option[SymbolUsage] =
  ## Uses --defusages to find symbol usage/defintion
  ## Uses IC so isn't braindead slow which is cool, but zero clue
  ## what stability is like lol
  # Use refc to get around https://github.com/nim-lang/Nim/issues/22205
  let (outp, status) = handle.execProcess("nim", @["check", "--ic:on", "--mm:refc", fmt"--defusages:{file},{pos.line + 1},{pos.character + 1}"] & ourOptions & $file.path)
  echo outp
  if status == QuitFailure: return
  var s = SymbolUsage()
  for lineStr in outp.splitLines():
    var
      file = ""
      line = -1
      col = -1
    # TODO: Fix navigator.nim so that the RHS of identDefs isn't considered a decl
    if lineStr.scanf("def$s$+($i, $i)", file, line, col):
      s.def = (file, initPos(line, col))
    elif lineStr.scanf("usage$s$+($i, $i)", file, line, col):
      s.usages &= (file, initPos(line, col))
  return some s

func toDiagnosticSeverity(x: sink string): Option[DiagnosticSeverity] =
  ## Returns the diagnostic severity for a string e.g. Hint, Warning
  case x
  of "Hint": some DiagnosticSeverity.Hint
  of "Warning": some DiagnosticSeverity.Warning
  of "Error": some DiagnosticSeverity.Error
  else: none(DiagnosticSeverity)

proc getErrors*(handle: RequestHandle, x: DocumentUri): seq[ParsedError] {.gcsafe.} =
  ## Parses errors from `nim check` into a more structured form
  let file = handle.getRawFile(x)
  if file.errors.len > 0: return file.errors

  let (outp, exitCode) = handle.execProcess(
    "nim",
    @["check"] & ourOptions & "-",
    input=file.content,
    workingDir = $x.path.parentDir()
  )

  let (fIdx, root) = handle.parseFile(x)
  for error in outp.split('\31'):
    let lines = error.splitLines()
    for i in 0..<lines.len:
      var (ok, file, line, col, lvl, msg) = lines[i].scanTuple("$+($i, $i) $+: $+")
      let sev = lvl.toDiagnosticSeverity()
      # stdin means its this file, so update it
      if file == "stdinfile.nim":
        file = $x.path
      if file != $x.path: continue
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
  file.errors = result

proc getDiagnostics*(handle: RequestHandle, x: DocumentUri): seq[Diagnostic] {.gcsafe.} =
  for err in handle.getErrors(x):
     result &= Diagnostic(
        range: err.range,
        severity: some err.severity,
        message: $err,
      )
