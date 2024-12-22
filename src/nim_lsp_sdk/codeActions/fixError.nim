## Contains fixes for parsed errors

{.used.}

import ../[errors, types, params, server, customast, nim_check]
import ../utils/ast
import ./utils
import std/[strformat, options, tables, sugar]


proc createFix*(e: ParsedError, node: NodePtr, diagnotic: Diagnostic): seq[CodeAction] =
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
              DocumentURI("file://" & e.location.file): @[node.editWith(newIdentNode(option))]
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
  let tree = handle.parseFile(params.textDocument.uri).ast

  # Lookup the nodes for each error
  let mappedErrors = collect:
    for error in handle.getErrors(params.textDocument.uri):
      let node = tree.findNode(error.location)
      if node.isSome():
        (error, tree.getPtr(node.unsafeGet()))

  for diag in params.context.diagnostics:
    for (error, node) in mappedErrors:
      # TODO: Not make this this bad
      if node.initRange == diag.range:
        result &= error.createFix(node, diag)

registerProvider(fixError)
