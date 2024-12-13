
import std/[strscans, strutils, syncio, json, jsonutils, options, strformat, tables, sequtils, paths, files]
import std/macros
import "$nim"/compiler/ast
import nim_lsp_sdk/[nim_check, server, protocol, customast]

import nim_lsp_sdk/[types, params, methods, utils, logging, errors]

from nim_lsp_sdk/utils/ast import newIdentNode

import std/locks
import std/os
using s: var Server

proc checkFile(handle: RequestHandle, uri: DocumentUri) {.gcsafe.} =
  ## Publishes `nim check` dianostics
  let diagnostics = handle.getDiagnostics(uri)
  sendNotification("textDocument/publishDiagnostics", PublishDiagnosticsParams(
    uri: uri,
    diagnostics: diagnostics
  ))


import nim_lsp_sdk/utils

addHandler(newLSPLogger())

# discard RenameFileOptions(
#   overwrite: some true,
#   ignoreIfExists: some false
# )

var lsp = initServer("CTN")

var
  currentCheckLock: Lock
  currentCheck {.guard: currentCheckLock.}: string

initLock(currentCheckLock)

lsp.listen(sendDiagnostics) do (h: RequestHandle, params: DocumentUri) {.gcsafe.}:
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

lsp.listen(changedNotification) do (h: RequestHandle, params: DidChangeTextDocumentParams) {.gcsafe.}:
  h.updateFile(params)
  h.server[].queue(sendDiagnostics.newMessage(params.textDocument.uri))

lsp.listen(openedNotification) do (h: RequestHandle, params: DidOpenTextDocumentParams) {.gcsafe.}:
  h.updateFile(params)
  h.server[].queue(sendDiagnostics.newMessage(params.textDocument.uri))

lsp.listen(savedNotification) do (h: RequestHandle, params: DidSaveTextDocumentParams) {.gcsafe.}:
  discard

lsp.listen(selectionRange) do (h: RequestHandle, params: SelectionRangeParams) -> seq[SelectionRange] {.gcsafe.}:
  let root = h.parseFile(params.textDocument.uri).ast
  result = newSeqOfCap[SelectionRange](params.positions.len)
  for pos in params.positions:
    let node = root[].findNode(pos)
    if node.isSome():
      result &= root.toSelectionRange(node.unsafeGet())

lsp.listen(codeAction) do (h: RequestHandle, params: CodeActionParams) -> seq[CodeAction] {.gcsafe.}:
  # Find actions for errors
  # Literal braindead implementation. Rerun the checks and try to match it up.
  # Need to do something like
  let errors = h.getErrors(params.textDocument.uri)
  # First we find the error that matches. Since they are parsed the same we should
  # be able to line them up exactly
  for err in errors:
    for diag in params.context.diagnostics:
      if err.range == diag.range:
        result &= err.createFix(diag)

lsp.listen(symbolDefinition) do (h: RequestHandle, params: TextDocumentPositionParams) -> Option[Location] {.gcsafe.}:
  let usages = h.findUsages(params.textDocument.uri, params.position)
  if usages.isSome():
    let usages = usages.unsafeGet()
    return some Location(
      uri: DocumentURI("file://" & usages.def[0]),
      range: Range(
        start: usages.def[1],
        `end`: Position(line: usages.def[1].line, character: usages.def[1].character + 1)
      )
    )


lsp.listen(documentSymbols) do (h: RequestHandle, params: DocumentSymbolParams) -> seq[DocumentSymbol] {.gcsafe.}:
  return h.parseFile(params.textDocument.uri).ast.getPtr(NodeIdx(0)).outLineDocument()

lsp.listen(initialNotification) do (h: RequestHandle, params: InitializedParams):
  logging.info("Client initialised")
  # Check that if there is a nimble.lock file, there is a nimble.paths file.
  # This stops the issue of wondering why nim check is complaining about not
  # finding libraries
  for root in h.server[].roots:
    let
      pathsFile = root/"nimble.paths"
      lockFile = root/"nimble.lock"
    if not (fileExists(lockFile) and fileExists(pathsFile)):
      debug "Not initialised"
      h.server[].showMessageRequest("Hello", Debug, ["AAAA"])



lsp.poll()
