## Utils for working with Nim check
import std/[osproc, strformat, logging, strscans, strutils, options, sugar, jsonutils, os, streams, tables, paths]
import types, hooks, server, params, errors

import utils/ast

import customast

import "$nim"/compiler/[parser, ast, idents, options, msgs, pathutils, syntaxes, lineinfos, llstream]

## Common options for checking errors in a file
const ourOptions = @[
  "--hint:Conf:off",
  "--hint:SuccessX:off",
  "--processing:off",
  "--errorMax:0",
  "--unitSep:on",
  "--colors:off"
]

func makeOptions(file: DocumentURI): seq[string] =
  ## Returns a list of options that should be applied to a file type
  result = @[]
  if file.path.splitFile.ext in [".nimble", ".nims"]:
    result &= ["--include:system/nimscript"]

proc exploreAST*(x: NodePtr, filter: proc (x: NodePtr): bool,
                   handler: proc (x: NodePtr): bool) {.effectsOf: [filter, handler].}=
  ## Helper function to explore the AST
  ## - filter: proc to determine if the handler should be called
  ## - handler: proc called on each node, only recurses if it returns true
  if not filter(x) or handler(x):
    if x[].hasSons:
      for child in x:
        exploreAST(child, filter, handler)

proc ofKind(x: set[TNodeKind]): (proc (x: NodePtr): bool) =
  proc (node: NodePtr): bool = node[].kind in x

func toSymbolKind(x: NodePtr): SymbolKind =
  ## Converts from Nim NodeKind into LSP SymbolKind
  case x[].kind
  of nkEnumFieldDef:
    EnumMember
  of nkFuncDef, nkProcDef:
    Function
  of nkMethodDef:
    Method
  of nkTypeDef:
    case x[2][].kind:
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

proc toDocumentSymbol(x: NodePtr, kind = x.toSymbolKind()): DocumentSymbol =
  DocumentSymbol(
    name: x.name,
    kind: kind,
    range: x.initRange(),
    selectionRange: x.nameNode.initRange()
  )


# TODO: Clean up this whole process
# Maybe make a genxeric if kind: body: recurse children thing?
proc collectTypeFields(x: NodePtr, symbols: var seq[DocumentSymbol]) =
  if x[].kind == nkIdentDefs:
    symbols &= x.toDocumentSymbol(kind=Property)
  elif x[].hasSons:
    for child in x:
      child.collectTypeFields(symbols)

proc collectIdentDefs(x: NodePtr): seq[DocumentSymbol] =
  var res: seq[DocumentSymbol]
  x.exploreAST(ofKind({nkIdentDefs, nkConstDef})) do (node: NodePtr) -> bool:
    for child in node[].sons[0 ..< ^2]:
      res &= x.getPtr(child).toDocumentSymbol()
  return res

proc collectType(node: NodePtr): DocumentSymbol =
  ## Collects a document symbol for a type definition
  assert node[].kind == nkTypeDef, "Must be a type section"

  let syms = node.toDocumentSymbol()

  syms.children &= node.collectIdentDefs()

  node.exploreAST(ofKind({nkEnumTy})) do (node: NodePtr) -> bool:
    node.exploreAST(ofKind({nkIdent, nkEnumFieldDef})) do (node: NodePtr) -> bool:
      syms.children &= (if node[].kind == nkIdent: node else: node[0]).toDocumentSymbol()
  return syms

proc outlineDocument*(x: NodePtr): seq[DocumentSymbol] =
  ## Creates an outline of symbols in the document.
  ## TODO: Check if the client supports heirarchy or not
  var symbols = newSeq[DocumentSymbol]()
  # Explore top level decls
  for node in x:
    case node[].kind
    of nkVarSection..nkConstSection:
      symbols &= node.collectIdentDefs()
    of nkProcDef..nkIteratorDef:
      symbols &= node.toDocumentSymbol()
    of nkTypeSection:
      node.exploreAST(ofKind({nkTypeDef})) do (node: NodePtr) -> bool:
        symbols &= node.collectType()
    else: discard
  return symbols

func contains*(r: Range, p: Position): bool =
  ## Returns true if a position is within a range
  # For start/end, we need to check columns
  if p.line == r.start.line:
    return p.character >= r.start.character
  if p.line == r.`end`.line:
    return p.character <= r.`end`.character
  # For everything else we can just check that its in between
  return p.line in r.start.line .. r.`end`.line

func contains*(r: Range, p: NodePtr): bool =
  ## Returns true if a node is within a range
  p[].info.initPos in r

type
  SymbolUsage* = object
    ## Information storing symbol usage
    def*: (string, Position)
    usages*: seq[(string, Position)]

proc raiseCancelled() {.raises: [ServerError].} =
    raise (ref ServerError)(code: RequestCancelled)

proc execProcess*(handle: RequestHandle, cmd: string, args: openArray[string], input = "", workingDir=""): tuple[output: string, code: int] =
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

proc getErrors*(handle: RequestHandle, x: DocumentUri): seq[ParsedError] {.gcsafe.} =
  ## Parses errors from `nim check` into a more structured form
  # See if we can get errors from the cache
  let file = handle.getRawFile(x)
  if file.errors.len > 0: return file.errors

  # If not, then run the compiler to get the messages
  let (outp, exitCode) = handle.execProcess(
    "nim",
    @["check"] & ourOptions & makeOptions(x) & "-",
    input=file.content,
    workingDir = $x.path.parentDir()
  )

  # Store the errors in the cache
  file.errors = result

proc getDiagnostics*(handle: RequestHandle, x: DocumentUri): seq[Diagnostic] {.gcsafe.} =
  ## Returns all the diagnostics for a document.
  ## Mainly just converts the stored errors into Diagnostics
  let root = handle.parseFile(x).ast
  for err in handle.getErrors(x):
    # Convert from basic line info into extended line info (i.e. is full range from AST)
    let range = root.toRange(err.location)
    if range.isNone: continue

    # Convert relevant information
    let info = collect:
      for related in err.relatedInfo:
        DiagnosticRelatedInformation(
          location: root.toLocation(related.location).unsafeGet(),
          message: related.msg
        )


    # Now just carry across the info
    result &= Diagnostic(
      range: range.unsafeGet(),
      severity: some err.severity,
      message: $err,
      relatedInformation: if info.len > 0: some info
                          else: none(seq[DiagnosticRelatedInformation])
    )
