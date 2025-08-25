
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

proc checkFile(handle: RequestHandle, uri: DocumentUri) {.gcsafe.} =
  ## Publishes `nim check` dianostics
  writeWith filesLock:
    {.gcsafe.}:
      let diagnostics = handle.getDiagnostics(fileStore, uri)
    sendNotification(publishDiagnostics, PublishDiagnosticsParams(
      uri: uri,
      diagnostics: diagnostics
    ))

addHandler(newLSPLogger())

var lsp = initServer("NimSight")

var
  currentCheckLock: Lock
  currentCheck {.guard: currentCheckLock.}: string

initLock(currentCheckLock)

lsp.listen[:DocumentURI, void, false](sendDiagnostics) do (h: RequestHandle, params: DocumentUri) {.gcsafe.}:
  try:
    # Cancel any previous request, then register this as the latest
    {.gcsafe.}:
      withLock currentCheckLock:
        h.server[].cancel(currentCheck)
        currentCheck = h.id.unsafeGet()
    sleep 100
    h.checkFile(params)
  except ServerError as e:
    # Ignore cancellations
    if e.code != RequestCancelled:
      raise e

lsp.listen[:DidChangeTextDocumentParams, void, false](changedNotification) do (h: RequestHandle, params: DidChangeTextDocumentParams) {.gcsafe.}:
  updateFile(params)
  h.server[].queue(sendDiagnostics.init(params.textDocument.uri))

lsp.listen[:DidOpenTextDocumentParams, void, false](openedNotification) do (h: RequestHandle, params: DidOpenTextDocumentParams) {.gcsafe.}:
  updateFile(params)
  h.server[].queue(sendDiagnostics.init(params.textDocument.uri))

lsp.listen[:DidSaveTextDocumentParams, void, false](savedNotification) do (h: RequestHandle, params: DidSaveTextDocumentParams) {.gcsafe.}:
  discard

lsp.listen(selectionRange) do (h: RequestHandle, params: SelectionRangeParams) -> seq[SelectionRange] {.gcsafe.}:
  writeWith filesLock:
    {.gcsafe.}:
      let root = fileStore.parseFile(params.textDocument.uri).ast
    result = newSeqOfCap[SelectionRange](params.positions.len)
    for pos in params.positions:
      let node = root[].findNode(pos)
      if node.isSome():
        result &= root.toSelectionRange(node.unsafeGet())

lsp.listen(codeAction) do (h: RequestHandle, params: CodeActionParams) -> seq[CodeAction] {.gcsafe.}:
  # Find the node that the params are referring to
  writeWith filesLock:
    {.gcsafe.}:
      return getCodeActions(h, fileStore, params)

lsp.listen(symbolDefinition) do (h: RequestHandle, params: TextDocumentPositionParams) -> Option[Location] {.gcsafe.}:
  # See if we can find a unique symbol in the outline
  writeWith filesLock:
    {.gcsafe.}:
      # Build AST and find the node the user is pointing at
      let document = fileStore.parseFile(params.textDocument.uri).ast
      let nodeUnder = document[].findNode(params.position)
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
            uri: params.textDocument.uri,
            range: symbol.range
          )

lsp.listen(documentSymbols) do (
  h: RequestHandle,
  params: DocumentSymbolParams
) -> seq[DocumentSymbol] {.gcsafe.}:
  writeWith filesLock:
    {.gcsafe.}:
      return fileStore.parseFile(params.textDocument.uri).ast.getPtr(NodeIdx(0)).outLineDocument()

lsp.listen[:InitializedParams, void, false](initialized) do (h: RequestHandle, params: InitializedParams):
  logging.info("Client initialised")
  # Check that if there is a nimble.lock file, there is a nimble.paths file.
  # This stops the issue of wondering why nim check is complaining about not
  # finding libraries
  # TODO: Ask to update lock file if nimble file is updated
  for root in h.server[].roots:
    let
      pathsFile = root/"nimble.paths"
      lockFile = root/"nimble.lock"
    debug fmt"Checking {root} for nimble initialisation"
    if fileExists(lockFile) and not fileExists(pathsFile):
      let msg = """
        Nimble doesn't seem to be initialised. This can cause problems with checking
        external libraries. Do you want me to initialise it?
      """.dedent()
      let answer = h.server[].showMessageRequest(msg, Debug, BooleanChoice)
      if answer.get(No) == Yes:
        discard h.execProcess("nimble", ["setup"], workingDir = $root)


lsp.poll()
