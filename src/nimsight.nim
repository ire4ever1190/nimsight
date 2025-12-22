
import std/[strutils, json, jsonutils, options, strformat, tables, paths, files]

import nimsight/sdk/[server, types, methods, protocol, params, logging]
import nimsight/[nimCheck, customast, codeActions, files, utils]

import std/[locks, os]

import pkg/threading/rwlock

type
  BooleanChoice = enum
    Yes
    No

using s: var Server

var filesLock = createRwLock()
var fileStore {.guard: filesLock.} = initFileStore(20) # TODO: Make this configurable

proc updateFile(params: DidChangeTextDocumentParams) {.gcsafe.} =
  ## Updates file cache with updates
  let doc = params.textDocument
  assert params.contentChanges.len <= 1, "Only full updates are supported"
  writeWith filesLock:
    for change in params.contentChanges:
      {.gcsafe.}:
        fileStore.put(doc.uri, change.text, doc.version)

proc updateFile*(params: DidOpenTextDocumentParams) {.gcsafe.} =
  ## Updates file cache with an open item
  let doc = params.textDocument
  writeWith filesLock:
    {.gcsafe.}:
      fileStore.put(doc.uri, doc.text, doc.version)

proc checkFile(ctx: NimContext, uri: DocumentUri) {.gcsafe.} =
  ## Publishes `nim check` dianostics
  writeWith filesLock:
    {.gcsafe.}:
      let diagnostics = ctx.getDiagnostics(fileStore, uri)
    sendNotification(publishDiagnostics, PublishDiagnosticsParams(
      uri: uri,
      diagnostics: diagnostics
    ))

addHandler(newLSPLogger())

var lsp = initServer("NimSight")

var
  currentCheckLock: Lock
  currentCheck {.guard: currentCheckLock.}: JsonNode

initLock(currentCheckLock)

lsp.on(sendDiagnostics.meth) do (ctx: NimContext, params: DocumentUri) {.gcsafe.}:
  try:
    # Cancel any previous request, then register this as the latest
    {.gcsafe.}:
      withLock currentCheckLock:
        ctx.cancel(currentCheck)
        currentCheck = ctx.id.unsafeGet()
    sleep 100
    ctx.checkFile(params)
  except ServerError as e:
    # Ignore cancellations
    if e.code != RequestCancelled:
      raise e

lsp.on(changedNotification.meth) do (ctx: NimContext, params: DidChangeTextDocumentParams) {.gcsafe.}:
  updateFile(params)
  ctx.data[].queue(sendDiagnostics.init(params.textDocument.uri))

lsp.on(openedNotification.meth) do (ctx: NimContext, params: DidOpenTextDocumentParams) {.gcsafe.}:
  updateFile(params)
  ctx.data[].queue(sendDiagnostics.init(params.textDocument.uri))

lsp.on(savedNotification.meth) do (ctx: NimContext, params: DidSaveTextDocumentParams) {.gcsafe.}:
  discard

lsp.on(selectionRange.meth) do (ctx: NimContext, params: SelectionRangeParams) -> seq[SelectionRange] {.gcsafe.}:
  writeWith filesLock:
    {.gcsafe.}:
      let root = fileStore.parseFile(params.textDocument.uri).ast
    result = newSeqOfCap[SelectionRange](params.positions.len)
    for pos in params.positions:
      let node = root[].findNode(pos)
      if node.isSome():
        result &= root.toSelectionRange(node.unsafeGet())

lsp.on(codeAction.meth) do (ctx: NimContext, params: CodeActionParams) -> seq[CodeAction] {.gcsafe.}:
  # Find the node that the params are referring to
  writeWith filesLock:
    {.gcsafe.}:
      return getCodeActions(ctx, fileStore, params)

lsp.on(symbolDefinition.meth) do (ctx: NimContext, params: TextDocumentPositionParams) -> Option[Location] {.gcsafe.}:
  let usages = ctx.findUsages(params.textDocument.uri, params.position)
  if usages.isSome():
    let usages = usages.unsafeGet()
    return some Location(
      uri: DocumentURI("file://" & usages.def[0]),
      range: Range(
        start: usages.def[1],
        `end`: Position(line: usages.def[1].line, character: usages.def[1].character + 1)
      )
    )


lsp.on(documentSymbols.meth) do (
  ctx: NimContext,
  params: DocumentSymbolParams
) -> seq[DocumentSymbol] {.gcsafe.}:
  writeWith filesLock:
    {.gcsafe.}:
      return fileStore.parseFile(params.textDocument.uri).ast.getPtr(NodeIdx(0)).outLineDocument()

lsp.on(initialized.meth) do (ctx: NimContext, params: InitializedParams):
  logging.info("Client initialised")
  # Check that if there is a nimble.lock file, there is a nimble.paths file.
  # This stops the issue of wondering why nim check is complaining about not
  # finding libraries
  # TODO: Ask to update lock file if nimble file is updated
  for root in ctx.data[].roots:
    let
      pathsFile = root/"nimble.paths"
      lockFile = root/"nimble.lock"
    debug fmt"Checking {root} for nimble initialisation"
    if fileExists(lockFile) and not fileExists(pathsFile):
      let msg = """
        Nimble doesn't seem to be initialised. This can cause problems with checking
        external libraries. Do you want me to initialise it?
      """.dedent()
      let answer = ctx.data[].showMessageRequest(msg, Debug, BooleanChoice)
      if answer.get(No) == Yes:
        discard ctx.execProcess("nimble", ["setup"], workingDir = $root)

# Special handlers, should be handled earlier in case server is busy
lsp.on("$/cancelRequest") do (id: JsonNode, ctx: Context):
  info "Cancelling ", request.params["id"]
  ctx.cancel(params.id)

lsp.on("shutdown") do (ctx: NimContext):
  info "Shutting down"
  ctx.data[].shutdown()

lsp.on("exit") do (ctx: NimContext):
  info "Exiting"
  quit int(ctx.data[].isRunning)

lsp.poll()
