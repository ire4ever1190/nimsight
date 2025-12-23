
import std/[strutils, json, jsonutils, options, strformat, tables, paths, files]

import nimsight/sdk/[server, types, methods, protocol, params, logging]
import nimsight/[nimCheck, customast, codeActions, files, utils]

import nimsight/utils/locks

import std/[locks, os]

import pkg/threading/[rwlock, channels]
import pkg/jaysonrpc

type
  BooleanChoice = enum
    Yes
    No

using s: var Server

var fileStore = protectReadWrite(initFileStore(20)) # TODO: Make this configurable

proc updateFile(params: DidChangeTextDocumentParams) {.gcsafe.} =
  ## Updates file cache with updates
  let doc = params.textDocument
  debug fmt"Updating {doc.uri} in cache"

  assert params.contentChanges.len <= 1, "Only full updates are supported"
  fileStore.with do (files: var FileStore):
    for change in params.contentChanges:
      files.put(doc.uri, change.text, doc.version)

proc updateFile*(doc: TextDocumentItem) {.gcsafe.} =
  ## Updates file cache with an open item

  debug fmt"Adding {doc.uri} to cache"
  fileStore.with do (files: var FileStore):
    files.put(doc.uri, doc.text, doc.version)

proc checkFile(ctx: NimContext, uri: DocumentUri) {.gcsafe.} =
  ## Publishes `nim check` dianostics
  fileStore.with do (files: var FileStore):
    let diagnostics = ctx.getDiagnostics(files, uri)
    sendNotification(publishDiagnostics, PublishDiagnosticsParams(
      uri: uri,
      diagnostics: diagnostics
    ))

addHandler(newLSPLogger())

var lsp = initServer("NimSight")

var currentCheck = protectReadWrite(newJNull())

const sendDiagnostics = MethodDef[tuple[uri: DocumentURI], void](name: "extension/internal/sendDiagnostics")

lsp.on(sendDiagnostics.name) do (ctx: NimContext, uri: DocumentUri) {.gcsafe.}:
  try:
    # Cancel any previous request, then register this as the latest
    currentCheck.with do (check: var JsonNode):
        ctx.cancel(check)
        check = ctx.id.unsafeGet()
    sleep 100
    ctx.checkFile(uri)
  except ServerError as e:
    # Ignore cancellations
    if e.code != RequestCancelled:
      raise e

proc requestDiagnostics(ctx: NimContext, uri: DocumentURI) =
  ## Requests the server to send diagnostics to the client
  ctx.data[].queue.send($ sendDiagnostics.notify((uri,)).toJson())

lsp.on(changedNotification.meth) do (ctx: NimContext, textDocument: VersionedTextDocumentIdentifier, contentChanges: seq[TextDocumentContentChangeEvent]) {.gcsafe.}:
  updateFile(DidChangeTextDocumentParams(textDocument: textDocument, contentChanges: contentChanges))
  ctx.requestDiagnostics(textDocument.uri)

lsp.on(openedNotification.meth) do (ctx: NimContext, textDocument: TextDocumentItem) {.gcsafe.}:
  updateFile(textDocument)
  ctx.requestDiagnostics(textDocument.uri)

lsp.on(savedNotification.meth) do (ctx: NimContext, textDocument: VersionedTextDocumentIdentifier) {.gcsafe.}:
  ctx.requestDiagnostics(textDocument.uri)

lsp.on("textDocument/didClose") do (textDocument: TextDocumentIdentifier):
  fileStore.with do (files: var FileStore):
    files.del(textDocument.uri)

lsp.on(selectionRange.meth) do (ctx: NimContext, params: SelectionRangeParams) -> seq[SelectionRange] {.gcsafe.}:
  fileStore.with do (files: var FileStore) -> seq[SelectionRange]:
    let root = files.parseFile(params.textDocument.uri).ast
    result = newSeqOfCap[SelectionRange](params.positions.len)
    for pos in params.positions:
      let node = root[].findNode(pos)
      if node.isSome():
        result &= root.toSelectionRange(node.unsafeGet())

lsp.on(codeAction.meth) do (ctx: NimContext, textDocument: TextDocumentIdentifier, range: Range, context: CodeActionContext) -> seq[CodeAction] {.gcsafe.}:
  # Find the node that the params are referring to
  fileStore.with do (files: var FileStore) -> seq[CodeAction]:
    return getCodeActions(ctx, files, CodeActionParams(
      textDocument: textDocument,
      range: range,
      context: context
    ))

lsp.on(symbolDefinition.meth) do (ctx: NimContext, textDocument: TextDocumentIdentifier, position: Position) -> Option[Location] {.gcsafe.}:
  let usages = ctx.findUsages(textDocument.uri, position)
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
  textDocument: TextDocumentIdentifier
) -> seq[DocumentSymbol] {.gcsafe.}:
  fileStore.with do (files: var FileStore) -> seq[DocumentSymbol]:
    return files.parseFile(textDocument.uri).ast.getPtr(NodeIdx(0)).outLineDocument()

lsp.on(initialized.meth) do (ctx: NimContext):
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
lsp.on("$/cancelRequest") do (id: JsonNode, ctx: NimContext):
  info "Cancelling ", id
  ctx.cancel(id)

lsp.on("shutdown") do (ctx: NimContext):
  info "Shutting down"
  ctx.data[].shutdown()

lsp.on("exit") do (ctx: NimContext):
  info "Exiting"
  quit int(ctx.data[].isRunning)

lsp.poll()
