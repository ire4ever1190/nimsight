
import std/[strscans, strutils, syncio, json, jsonutils, options, strformat, tables]
import std/macros
import std/logging
import nim_lsp_sdk/[nim_check, server, protocol]

import nim_lsp_sdk/[types, params, methods, utils]

var fileLog = newFileLogger("/tmp/errors.log")
addHandler(fileLog)

using s: var Server

proc checkFile(params: DidOpenTextDocumentParams | DidChangeTextDocumentParams) =
  ## Publishes `nim check` dianostics
  let doc = params.textDocument
  sendNotification("textDocument/publishDiagnostics", PublishDiagnosticsParams(
    uri: doc.uri,
    version: some doc.version,
    diagnostics: getErrors(doc.uri.replace("file://", ""))
  ))
import nim_lsp_sdk/utils


var lsp = initServer("CTN")


# s
lsp.listen(changedNotification) do (s: var Server, params: DidChangeTextDocumentParams):
  checkFile(params)
lsp.listen(openedNotification) do (s: var Server, params: DidOpenTextDocumentParams):
  checkFile(params)
lsp.listen(symbolDefinition) do (s: var Server, params: TextDocumentPositionParams) -> Option[Location]:
  let usages = findUsages(params.textDocument.uri.replace("file://"), params.position)
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

lsp.poll()
