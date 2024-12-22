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
    debug n
    debug "Not an ident"
    return
  let parent = n.parent
  if parent.kind != nkTypeDef:
    debug parent
    debug "Not in a type def"
    return

  # Find all the idents
  var idents = newSeq[NodeIdx]()
  ast[].getObjectIdents(ast[][node].parent, idents)

  # And make edits to export them
  var edits = collect:
    for ident in idents:
      ast.getPtr(ident).editWith(ast[].toPNode(ident).postfix(newIdentNode("*")))
  if edits.len == 0:
    debug "no edits"
    return

  debug "Got deits"
  # Now push everything into a code action
  return @[CodeAction(
    title: fmt"Make '{n.name}' public",
    diagnostics: none seq[Diagnostic],
    edit: some WorkspaceEdit(
      changes: some toTable({
        params.textDocument.uri: edits
      })
    )
  )]

registerProvider(makeFieldsPublic)
