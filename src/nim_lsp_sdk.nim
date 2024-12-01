
import std/[strscans, strutils, syncio, json, jsonutils, options, strformat, tables]
import std/macros
import "$nim"/compiler/ast
import nim_lsp_sdk/[nim_check, server, protocol]

import nim_lsp_sdk/[types, params, methods, utils, logging]

# var fileLog = newFileLogger("/tmp/errors.log")
# addHandler(fileLog)

using s: var Server


proc checkFile(handle: RequestHandle, params: DidOpenTextDocumentParams | DidChangeTextDocumentParams | DidSaveTextDocumentParams) {.gcsafe.} =
  ## Publishes `nim check` dianostics
  let doc = params.textDocument
  debug "Checking: ", doc.uri
  let diagnostics = handle.getDiagnostics(doc.uri.replace("file://", ""))
  sendNotification("textDocument/publishDiagnostics", PublishDiagnosticsParams(
    uri: doc.uri,
    diagnostics: diagnostics
  ))


import nim_lsp_sdk/utils

addHandler(newLSPLogger())

# discard RenameFileOptions(
#   overwrite: some true,
#   ignoreIfExists: some false
# )

var lsp = initServer("CTN")

lsp.listen(changedNotification) do (h: RequestHandle, params: DidChangeTextDocumentParams) {.gcsafe.}:
  debug(params.text)
  h.checkFile(params)

lsp.listen(openedNotification) do (h: RequestHandle, params: DidOpenTextDocumentParams) {.gcsafe.}:
  h.checkFile(params)

lsp.listen(savedNotification) do (h: RequestHandle, params: DidSaveTextDocumentParams) {.gcsafe.}:
  h.checkFile(params)


lsp.listen(codeAction) do (h: RequestHandle, params: CodeActionParams) -> seq[CodeAction]:
  # Find actions for errors
  # Literal braindead implementation. Rerun the checks and try to match it up.
  # Need to do something like
  let errors = h.getErrors(params.textDocument.uri.replace("file://", ""))
  # First we find the error that matches. Since they are parsed the same we should
  # be able to line them up exactly
  debug params.context.diagnostics.len
  for err in errors:
    for diag in params.context.diagnostics:
      if err.range == diag.range:
        result &= err.createFix(diag)
        debug("Found error")
  debug result.len

lsp.listen(symbolDefinition) do (h: RequestHandle, params: TextDocumentPositionParams) -> Option[Location] {.gcsafe.}:
  let usages = h.findUsages(params.textDocument.uri.replace("file://"), params.position)
  debug($usages)
  if usages.isSome():
    let usages = usages.unsafeGet()
    return some Location(
      uri: "file://" & usages.def[0],
      range: Range(
        start: usages.def[1],
        `end`: Position(line: usages.def[1].line, character: usages.def[1].character + 1)
      )
    )


lsp.listen(documentSymbols) do (h: RequestHandle, params: DocumentSymbolParams) -> seq[DocumentSymbol] {.gcsafe.}:
  return params.textDocument.parseFile().outLineDocument()

lsp.listen(initialNotification) do (h: RequestHandle, params: InitializedParams):
  logging.info("Client initialised")

lsp.poll()
