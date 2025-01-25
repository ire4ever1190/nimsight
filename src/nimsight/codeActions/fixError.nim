## Contains fixes for parsed errors

{.used.}

import ../sdk/[types, params, server]
import ../[customast, nimCheck, errors]
import ../utils/ast
import ./utils
import std/[strformat, options, tables, sugar]


proc createFix*(e: ParsedError, node: NodePtr, diagnotics: seq[Diagnostic]): seq[CodeAction] =
  ## Returns possibly fixes for an error
  case e.kind
  of Unknown:
    result = newSeq[CodeAction]()
    for option in e.possibleSymbols:
      result &= CodeAction(
        title: fmt"Rename to `{option}`",
        diagnostics: some newSeq[Diagnostic](),
        kind: some QuickFix,
        edit: some WorkspaceEdit(
            changes: some toTable({
              DocumentURI("file://" & e.location.file): @[node.editWith(newIdentNode(option))]
            })
          )
      )
  else: discard


proc fixError(
  handle: RequestHandle,
  params: CodeActionParams,
  ast: Tree,
  node: NodeIdx): seq[CodeAction] =
  ## Create fixes for some errors/warnings that appear
  # Go through every error and create a fix.
  # Slighly wrong with how it works, need a way to line up diagnostics
  # with the errors

  # Lookup the nodes for each error
  let mappedErrors = collect:
    for error in handle.getErrors(params.textDocument.uri):
      let node = ast.findNode(error.location)
      if node.isSome():
        (error, ast.getPtr(node.unsafeGet()))

  let targetRange = ast.getPtr(node).initRange

  for (error, node) in mappedErrors:
    if node.initRange == targetRange:
      result &= error.createFix(node, params.context.diagnostics)

registerProvider(fixError)
