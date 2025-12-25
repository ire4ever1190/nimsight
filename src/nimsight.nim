
import std/[strutils, json, jsonutils, options, strformat, tables, paths, files]

import nimsight/sdk/[server, types, methods, protocol, params, logging]
import nimsight/[nimCheck, customast, codeActions, files, utils]

import nimsight/utils/locks

import std/[locks, os]

import pkg/threading/[rwlock, channels]
import pkg/[jaysonrpc, anano]

type
  BooleanChoice = enum
    Yes
    No

using s: var Server

# TODO: Only escalate to a write lock if needed, lot of the time we can get away with a read lock
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
  # Only establish the lock for getting the contents, lots of things need it
  let (content, root) = fileStore.with do (files: var FileStore) -> (string, Tree):
    let
      root = files.parseFile(uri).ast
      file = files.rawGet(uri)
    # TODO: add back caching
    # if file.ranCheck: return file.errors.toDiagnostics(root)
    return (file.content, root)

  let diagnostics = ctx.getDiagnostics(content, root, uri)
    # Store the errors in the cache
    # if not file.ranCheck and false:
    #   file.errors = result
    #   file.ranCheck = true

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
    # Cancel any previous request, then register this as the latest.
    # TODO: Make this request be per file
    currentCheck.with do (check: var JsonNode):
        ctx.cancel(check)
        check = ctx.id.unsafeGet()
    # Sleep so we debounce the request
    sleep 100
    if not ctx.isCancelled:
      ctx.checkFile(uri)
  except RPCError as e:
    # Ignore cancellations
    if e.code != RequestCancelled:
      raise e

proc requestDiagnostics(ctx: NimContext, uri: DocumentURI) =
  ## Requests the server to send diagnostics to the client
  var req = sendDiagnostics.call((uri,))
  req.id = $genNanoID()
  ctx.data[].queue.send($ req.toJson())

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
  # See if we can find a unique symbol in the outline
  let (document, nodeUnder) = fileStore.with do (files: var FileStore) -> (Tree, Option[NodeIdx]):
      # Build AST and find the node the user is pointing at
      let document = files.parseFile(textDocument.uri).ast
      return (document, document[].findNode(position))

  if nodeUnder.isNone(): return none(Location)

  # Check if the node is an identifier
  let foundNode = document[nodeUnder.unsafeGet()]
  if foundNode.kind != nkIdent: return none(Location)

  let targetName = foundNode.strVal.nimIdentNormalize()

  # Now search the outline, and return the first match
  let outline = document.getPtr(NodeIdx(0)).outLineDocument()
  for symbol in outline:
    if symbol.name.nimIdentNormalize() == targetName:
      return some Location(
        uri: textDocument.uri,
        range: symbol.selectionRange
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
