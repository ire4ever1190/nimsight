## Contains fixes for parsed errors

{.used.}

import ../[errors, types, params, server, customast, nim_check]
import ../utils/ast
import ./utils
import std/[strformat, options, tables]

import std/parseutils

proc createFix*(e: ParsedError, diagnotic: Diagnostic): seq[CodeAction] =
  ## Returns possibly fixes for an error
  case e.kind
  of Unknown:
    result = newSeq[CodeAction]()
    for option in e.possibleSymbols:
      result &= CodeAction(
        title: fmt"Rename to `{option}`",
        diagnostics: some @[diagnotic],
        edit: some WorkspaceEdit(
            changes: some toTable({
              DocumentURI("file://" & e.file): @[e.node.editWith(newIdentNode(option))]
            })
          )
      )
  else: discard


proc fixError(
  handle: RequestHandle,
  params: CodeActionParams,
  ast: TreeView,
  node: NodeIdx): seq[CodeAction] =
  ## Create fixes for some errors/warnings that appear
  # Go through every error and create a fix.
  # Slighly wrong with how it works, need a way to line up diagnostics
  # with the errors
  for diag in params.context.diagnostics:
    for error in handle.getErrors(params.textDocument.uri):
      if error.range == diag.range:
        result &= error.createFix(diag)

registerProvider(fixError)
