## Helper module that imports all the utils along with a few small snippets

import std/[macros, paths]

import utils/[locks, procmonitor, union]

macro mixed*(objs: varargs[typed]): typedesc =
  ## Simple mixin macro that allows for multi inheritance by
  ## creating a temp type that joins all the fields.
  ## Currently doesn't support fancy things like variant objects.
  ## Objects passed in should not inherit from the root obj
  var recordList = nnkRecList.newTree()
  # Get the fields from each object
  for obj in objs:
    for record in obj.getTypeImpl()[1].getImpl()[2][2]:
      recordList &= record

  let name = nskType.genSym("Mixed object")
  result = nnkTypeSection.newTree(nnkTypeDef.newTree(
    name,
    newEmptyNode(),
    nnkObjectTy.newTree(
      newEmptyNode(),
      nnkOfInherit.newTree(ident"RootObj"),
      recordList
    )
  ))
  result = newStmtList(result, name)

macro `case`*(x: ref): untyped =
  ## Creates a case statement that allows for easily doing multiple `of` branches.
  ## Each branch is casted into the type if it matches
  let tmpSym = genSym(nskLet, "")
  let init = newLetStmt(tmpSym, x[0])

  let ifStmt = nnkIfExpr.newTree()
  for i in 1..<x.len:
    let branch = x[i]
    if branch.kind == nnkOfBranch:
      for child in branch[0 ..< ^1]:
        let check = nnkInfix.newTree(ident"of", tmpSym, child)
        let body = branch[^1].copy()
        body.insert(0, newLetStmt(ident x[0].strVal, newCall(child, tmpSym)))
        ifStmt &= nnkElifBranch.newTree(check, body)
    elif branch.kind == nnkElse:
      ifStmt &= branch.copy()
  result = newStmtList(init, ifStmt)

func `/`*(a: Path, b: static[string]): Path = a / Path(b)

export locks, procmonitor, union
