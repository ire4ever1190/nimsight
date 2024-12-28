
import std/[strutils, json, jsonutils, options, strformat, tables, paths, files]
import nimsight/[nimCheck, server, protocol, customast]

import nimsight/[types, params, methods, utils, logging]

import nimsight/[codeActions, errors]

import std/locks
import std/os

type
  BooleanChoice = enum
    Yes
    No

using s: var Server


proc checkFile(handle: RequestHandle, uri: DocumentUri) {.gcsafe.} =
  ## Publishes `nim check` dianostics
  # Send the parser errors right away
  let ast = handle.parseFile(uri)
  sendNotification("textDocument/publishDiagnostics", PublishDiagnosticsParams(
    uri: uri,
    diagnostics: ast.errs.parseErrors($ uri.path, ast.ast).toDiagnostics(ast.ast)
  ))

  # Then let the other errors get sent
  let diagnostics = handle.getDiagnostics(uri)
  sendNotification("textDocument/publishDiagnostics", PublishDiagnosticsParams(
    uri: uri,
    diagnostics: diagnostics
  ))

addHandler(newLSPLogger())

var lsp = initServer("NimSight")

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
  # Find the node that the params are referring to
  return getCodeActions(h, params)

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


lsp.listen(documentSymbols) do (
  h: RequestHandle,
  params: DocumentSymbolParams
) -> seq[DocumentSymbol] {.gcsafe.}:
  return h.parseFile(params.textDocument.uri).ast.getPtr(NodeIdx(0)).outLineDocument()

lsp.listen(initialNotification) do (h: RequestHandle, params: InitializedParams):
  logging.info("Client initialised")
  # Check that if there is a nimble.lock file, there is a nimble.paths file.
  # This stops the issue of wondering why nim check is complaining about not
  # finding libraries
  # TODO: Ask to update lock file if nimble file is updated
  for root in h.server[].roots:
    let
      pathsFile = root/"nimble.paths"
      lockFile = root/"nimble.lock"
    if fileExists(lockFile) and not fileExists(pathsFile):
      let msg = """
        Nimble doesn't seem to be initialised. This can cause problems with checking
        external libraries. Do you want me to initialise it?
      """.dedent()
      let answer = h.server[].showMessageRequest(msg, Debug, BooleanChoice)
      if answer.get(No) == Yes:
        discard h.execProcess("nimble", ["setup"], workingDir = $root)


lsp.poll()
