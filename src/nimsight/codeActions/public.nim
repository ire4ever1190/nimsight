## Code actions that can make fields in an object public

{.used.}

import "$nim"/compiler/ast
import ../[errors, types, params, server, customast, nim_check]
import ../utils/ast
import ./utils
import std/[strformat, options, tables, sugar, logging]

proc getObjectIdents(x: TreeView, idx: NodeIdx, idents: var seq[NodeIdx]) =
  ## Recursive function to find all the idents inside an object
  let node = x[idx]
  debug node
  if node.kind == nkIdentDefs:
    for child in node.sons[0 ..< ^2]:
      if x[child].kind == nkIdent:
        idents &= child
  elif node.hasSons:
    for child in node.sons:
      getObjectIdents(x, child, idents)

proc makeFieldsPublic*(
  handle: RequestHandle,
  params: CodeActionParams,
  ast: Tree,
  node: NodeIdx): seq[CodeAction] =

  let n = ast.getPtr(node)
  # We only care about idents inside objects
  if n.kind != nkIdent:
    return
  let parent = n.parent({nkPostFix})
  if parent.kind != nkTypeDef:
    return

  # Find all the idents
  var idents = newSeq[NodeIdx]()
  ast[].getObjectIdents(parent.idx, idents)

  # And make edits to export them
  var edits = collect:
    for ident in idents:
      ast.getPtr(ident).editWith(ast[].toPNode(ident).postfix(newIdentNode("*")))
  if edits.len == 0:
    return

  # Now push everything into a code action
  return @[CodeAction(
    title: fmt"Make '{n.name}' fields public",
    diagnostics: none seq[Diagnostic],
    kind: some Refactor,
    edit: some WorkspaceEdit(
      changes: some toTable({
        params.textDocument.uri: edits
      })
    )
  )]

registerProvider(makeFieldsPublic)
