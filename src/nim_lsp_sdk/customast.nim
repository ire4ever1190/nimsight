## Custom AST that is flat instead of a tree. Haven't benchmarked but it probably faster to traverse
## compared to the normal AST. Supports getting the parent of a node.
## Implements the [customast](https://github.com/nim-lang/Nim/blob/devel/compiler/plugins/customast.nim) API
## to avoid needing to traverse the old tree to generate this

import "$nim"/compiler/[ast, lineinfos, idents]

import std/sequtils

type
  NodeIdx = uint32
    ## Index into the tree
  Node* {.acyclic.} = object
    info*, endInfo*: TLineInfo
    parent: NodeIdx
    case kind*: TNodeKind
    of nkCharLit..nkUInt64Lit:
      intVal*: BiggestInt
    of nkFloatLit..nkFloat128Lit:
      floatVal*: BiggestFloat
    of nkStrLit..nkTripleStrLit, nkIdent:
      strVal*: string
    else:
      sons*: seq[NodeIdx]

  Tree = seq[Node]
  TreeView = openArray[Node]

func root*(a: TreeView): Node =
  a[a.low]

iterator sons*(tree: TreeView, idx: NodeIdx): lent Node =
  for son in tree[idx].sons:
    yield tree[son]

func `==`*(a, b: Node): bool =
  ## Checks if two nodes are equal.
  ## This is only a partial equality since
  ## - `parent` isn't checked
  ## - only the length of `sons` is checked
  template compare(field: untyped): bool =
    a.field == b.field
  if not (compare(kind) and compare(info) and compare(endInfo)):
    return false

  case a.kind
  of nkCharLit..nkUInt64Lit:
    compare(intVal)
  of nkFloatLit..nkFloat128Lit:
    compare(floatVal)
  of nkStrLit..nkTripleStrLit, nkIdent:
    compare(strVal)
  else:
    a.sons.len == b.sons.len

func `==`*(a, b: TreeView): bool =
  let
    rootA = a.root
    rootB = b.root
  if rootB != rootB:
    return false

  for (sonA, sonB) in zip(rootA.sons, rootB.sons):
    if a.toOpenArray(sonA.int, a.high) != b.toOpenArray(sonB.int, b.high):
      return false

  return true

proc translate*(tree: var Tree, x: PNode, parent = default(NodeIdx)) =
  template copy(field: untyped) =
    node.field = x.field
  var node = Node(kind: x.kind, parent: parent)
  copy(info)
  copy(endInfo)
  case x.kind
  of nkCharLit..nkUInt64Lit:
    copy(intVal)
  of nkFloatLit..nkFloat128Lit:
    copy(floatVal)
  of nkStrLit..nkTripleStrLit:
    copy(strVal)
  of nkIdent:
    node.strVal = x.ident.s
  else: discard
  # Add into the tree, and update the parent to contain this
  # element in its child list
  tree &= node
  let currIdx = tree.high.NodeIdx
  if likely(parent != currIdx):
    tree[parent].sons &= currIdx
  # Now translate all the children
  for child in x:
    tree.translate(child, currIdx)

proc toTree*(node: PNode): Tree =
  result.translate(node)

proc toPNode*(tree: TreeView, idx: NodeIdx, cache = newIdentCache()): PNode =
  let node = tree[idx]
  result = PNode(kind: node.kind)
  template copy(field: untyped) =
    result.field = node.field

  copy(info)
  copy(endInfo)
  case node.kind
  of nkCharLit..nkUInt64Lit:
    copy(intVal)
  of nkFloatLit..nkFloat128Lit:
    copy(floatVal)
  of nkStrLit..nkTripleStrLit:
    copy(strVal)
  of nkIdent:
    result.ident = cache.getIdent(node.strVal)
  else:
    for son in node.sons:
      result.sons &= tree.toPNode(son, cache)

proc toPNode*(tree: TreeView): PNode =
  tree.toPNode(tree.low.NodeIdx)
