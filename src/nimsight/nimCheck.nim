## Utils for working with Nim check
import std/[osproc, strformat, options, sugar, os, streams, paths, logging]

import sdk/[types, hooks, server, params]

import utils/ast
import customast, errors, files

import "$nim"/compiler/ast

## Common options for checking errors in a file
const ourOptions = @[
  "--hint:Conf:off",
  "--hint:SuccessX:off",
  "--processing:off",
  "--errorMax:0",
  "--unitSep:on",
  "--colors:off"
]

func isNimscript(file: DocumentURI): bool =
  file.path.splitFile.ext in [".nimble", ".nims"]

func makeOptions(file: DocumentURI): seq[string] =
  ## Returns a list of options that should be applied to a file type
  result = @[fmt"--stdinfile:{file.path}"]
  if file.isNimscript:
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
  of nkFuncDef, nkProcDef, nkMacroDef, nkTemplateDef, nkIteratorDef, nkProcTy, nkIteratorTy:
    Function
  of nkMethodDef:
    Method
  of nkTypeClassTy:
    Interface
  of nkRefTy, nkObjectTy: # Not correct! nkRef could just be a type alias not an obkect
    Object
  of nkEnumTy:
    Enum
  of nkTypeDef:
   x[2].toSymbolKind()
  of nkIdent:
    # Depending on the parent, we change the type
    let parent = x.parent({nkIdentDefs, nkConstDef})
    case parent.kind
    of nkObjectTy:
      Field
    of nkEnumTy:
      EnumMember
    of nkConstSection:
      Constant
    else: Variable
  of nkPostFix:
    return x[0].toSymbolKind()
  else:
    {.cast(noSideEffect).}:
      warn "Cant get symbol for ", x[].kind
    # Likely not good enough
    Variable

proc toDocumentSymbol(x: NodePtr, kind = x.toSymbolKind()): DocumentSymbol =
  DocumentSymbol(
    name: x.name,
    kind: kind,
    range: x.initRange(),
    selectionRange: x.nameNode.initRange()
  )

proc collectIdentDefs(x: NodePtr): seq[DocumentSymbol] =
  var res: seq[DocumentSymbol]
  x.exploreAST(ofKind({nkIdentDefs, nkConstDef})) do (node: NodePtr) -> bool:
    for child in node[].sons[0 ..< ^2]:
      res &= x.getPtr(child).toDocumentSymbol()
  return res


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
      for typeDef in node:
        var sym = typeDef.toDocumentSymbol()

        # Go through every field. We want to get identDefs so we don't recurse into the right
        # hand and get procTy nodes
        const careAbout = {nkIdentDefs, nkIdent, nkEnumFieldDef,  nkProcDef..nkIteratorDef}
        typeDef[2].exploreAst(ofKind(careAbout)) do (node: NodePtr) -> bool:
          if node.kind == nkIdentDefs:
            for i in 0 ..< node.len - 2:
              sym.children &= node[i].toDocumentSymbol()
          else:
            sym.children &= node.toDocumentSymbol()
        symbols &= sym
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

  debug(fmt"Running `{cmd}` with args {args} in '{workingDir}'")

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

proc getErrors*(handle: RequestHandle, file: NimFile, x: DocumentUri): seq[ParsedError] {.gcsafe.} =
  ## Parses errors from `nim check` into a more structured form
  # See if we can get errors from the cache
  if file.ranCheck: return file.errors
  # If not, then run the compiler to get the messages
  let (outp, _) = handle.execProcess(
    "nim",
    @["check"] & ourOptions & makeOptions(x) & "-",
    input=file.content,
    workingDir = $x.path.parentDir()
  )

  result = collect:
    for chunk in outp.msgChunks:
      let err = chunk.parseError()
      if err.location.file == x.path:
        err

  # Store the errors in the cache
  file.errors = result
  file.ranCheck = true


proc toDiagnostics*(
  errors: openArray[ParsedError],
  root: Tree
): seq[Diagnostic] {.gcsafe.} =
  ## Converts a list of errors into diagnostics
  for err in errors:
    # Convert from basic line info into extended line info (i.e. full range from AST)
    let range = root.toRange(err.location)
    if range.isNone: continue

    # Convert relevant information
    let info = collect:
      for related in err.relatedInfo:
        let location = root.toLocation(related.location)
        if location.isNone: continue

        DiagnosticRelatedInformation(
          location: location.unsafeGet(),
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


proc getDiagnostics*(handle: RequestHandle, files: var FileStore, x: DocumentUri): seq[Diagnostic] {.gcsafe.} =
  ## Returns all the diagnostics for a document.
  ## Mainly just converts the stored errors into Diagnostics
  let root = files.parseFile(x).ast
  handle.getErrors(files.rawGet(x), x).toDiagnostics(root)
