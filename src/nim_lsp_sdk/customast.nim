## Custom AST that is flat instead of a tree. Haven't benchmarked but it probably faster to traverse
## compared to the normal AST. Supports getting the parent of a node.
## Implements the [customast](https://github.com/nim-lang/Nim/blob/devel/compiler/plugins/customast.nim) API
## to avoid needing to traverse the old tree to generate this

import "$nim"/compiler/[ast, parser, syntaxes, options, msgs, idents, pathutils, lineinfos, llstream, renderer]

import std/[sequtils, options, strformat]

import types

import utils/ast

type
  NodeIdx* = uint32
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

  NodePtr* = object
    ## Fat pointer that can derefence a node.
    tree: Tree
    idx: NodeIdx

  Tree = ref seq[Node]
  TreeView = openArray[Node]

  ParsedFile* = tuple[idx: FileIndex, ast: Tree]

func `[]`*(p: NodePtr): lent Node {.gcsafe.} =
  ## Derefences a node
  p.tree[p.idx]

func `$`*(p: Node): string =
  return fmt"{p.kind} @ {p.info.line}:{p.info.col}"

func getPtr*(t: Tree, idx: NodeIdx): NodePtr =
  ## Gets a [NodePtr] for an index
  rangeCheck(idx.int in 0 ..< t[].len)
  NodePtr(
    tree: t,
    idx: idx
  )

func getPtr*(t: NodePtr, idx: NodeIdx): NodePtr =
  ## Creates a [NodePtr] using the tree stored inside `t`
  result = t
  result.idx = idx

func `[]`*(p: NodePtr, child: int): NodePtr =
  ## Returns the n'th son of a node
  result = p
  result.idx = p[].sons[child]

func root*(a: TreeView): Node =
  ## Returns the first node in a [Tree]
  a[a.low]

const noSons = {nkCharLit..nkUInt64Lit, nkFloatLit..nkFloat128Lit, nkStrLit..nkTripleStrLit, nkIdent}

func hasSons*(a: Node): bool {.inline.} =
  ## Returns tree if a node has sons and can be iterated through
  a.kind notin noSons

iterator sons*(tree: TreeView, idx: NodeIdx): lent Node =
  for son in tree[idx].sons:
    yield tree[son]

iterator items*(n: NodePtr): NodePtr =
  for son in n[].sons:
    yield n.getPtr(son)

func parent*(n: NodePtr): NodePtr =
  ## Returns the parent node
  n.getPtr(n[].parent)

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

func `==`*(a, b: Tree): bool =
  if a.isNil xor b.isNil:
    return false
  if a.isNil and b.isNil:
    return true
  a[] == b[]

proc translate*(tree: var seq[Node], x: PNode, parent = default(NodeIdx)) =
  ## Translates a [PNode] into a [Node] and adds it to `tree`
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
  let currIdx = (tree.len - 1).NodeIdx
  if likely(parent != currIdx):
    tree[parent].sons &= currIdx
  for son in x:
    tree.translate(son, currIdx)

proc toTree*(node: PNode): Tree =
  ## Converts a `PNode` into a tree
  result = new(Tree)
  result[].translate(node)

proc toPNode*(tree: TreeView, idx: NodeIdx, cache = newIdentCache()): PNode =
  ## Converts a node in the tree into a `PNode`
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
  ## Converts a custom AST into a `PNode`
  tree.toPNode(tree.low.NodeIdx)

proc ignoreErrors(conf: ConfigRef; info: TLineInfo; msg: TMsgKind; arg: string) =
  # TODO: Don't ignore errors
  discard

proc parseFile*(x: DocumentUri, content: sink string): ParsedFile {.gcsafe.} =
  ## Parses a document. Doesn't perform any semantic analysis
  var conf = newConfigRef()
  let fileIdx = fileInfoIdx(conf, AbsoluteFile x)
  var p: Parser
  {.gcsafe.}:
    parser.openParser(p, fileIdx, llStreamOpen(content), newIdentCache(), conf)
    defer: closeParser(p)
    p.lex.errorHandler = ignoreErrors
    result = (fileIdx, parseAll(p).toTree())

proc findNode*(t: TreeView, line, col: uint, careAbout: FileIndex): Option[NodeIdx] =
  ## Returns the index for a node that matches line col.
  # TODO: Do we need file index? Not like we can parse across files atm
  for idx, node in t:
    # TODO: Implement early escaping?
    # Issue is that for example `a and b` in a statement list wouldn't have
    # the line info nicely line up. Maybe track when going between scopes?
    let info = node.info
    if unlikely(info.line == line and info.col.uint == col and info.fileIndex == careAbout):
      result = some idx.NodeIdx

proc findNode*(t: Tree, line, col: uint, careAbout: FileIndex): Option[NodePtr] =
  # For some reason its faster to deference here than to derefence in the other (By a large margin).
  # Maybe if I deference directly then it dereferences every loop?
  let idx = t[].findNode(line, col, careAbout)
  if idx.isSome():
    return some t.getPtr(idx.unsafeGet())

proc nameNode*(x: NodePtr): NodePtr =
  ## Returns the node that stores the name
  case x[].kind
  of nkIdent:
    x
  of nkPostFix:
    x[1].nameNode
  of nkProcDef..nkIteratorDef, nkTypeDef, nkAccQuoted, nkIdentDefs:
    x[namePos].nameNode
  of nkPragmaExpr:
    x[0].nameNode
  else:
    raise (ref ValueError)(msg: fmt"Can't find name for {x[].kind} @ {x[].info.lineCol()}")

proc name*(x: NodePtr): string =
  x.nameNode[].strVal

func initRange*(p: NodePtr): Range =
  ## Creates a range from a node
  result = Range(start: p[].info.initPos(), `end`: p[].endInfo.initPos())
  if result.`end` < result.start:
    # The parser fails to set this correctly in a few spots.
    # Attempt to make it usable
    case p[].kind
    of nkIdent:
      result.`end`.line = result.start.line
      result.`end`.character = result.start.character + p.name.len.uint
    else:
      result.`end` = result.start

proc editWith*(original: NodePtr, update: PNode): TextEdit =
  ## Creates an edit that will replace `original` with `update`.
  {.gcsafe.}:
    return TextEdit(
      range: original.initRange,
      newText: update.renderTree({renderNonExportedFields}))
