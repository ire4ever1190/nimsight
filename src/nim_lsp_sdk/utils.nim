import std/[macrocache, macros, strformat, paths]

import threading/[rwlock]

import ./utils/union

const rpcMethods = CacheTable"lsp.rpcMethods"
  ## Mapping of method name to param/return type.
  ## This is for receiving messages from the client that
  ## get handled by the server

const rpcNotifications = CacheTable"lsp.rpcNotifications"
  ## Table of methods that are notifications.
  ## Just in case there is a method that returns null

macro registerServerMessage*(name: static[string], param, returnType: typedesc,
                            isNotification: static[bool]=false) =
  ## Registers a message that is client -> server.
  rpcMethods[name] = newStmtList(param, returnType)
  if isNotification:
    rpcNotifications[name] = newEmptyNode()

macro registerClientMessage*(name: static[string], param, returnType: typedesc,
                            isNotification: static[bool]=false) {.deprecated.}=
  ## Registers a method that is server -> client
  rpcMethods[name] = newStmtList(param, returnType)
  if isNotification:
    rpcNotifications[name] = newEmptyNode()

macro isNotification*(name: static[string]): bool =
  ## Returns true if an event is a notification
  ## i.e. shouldn't return a value
  newLit name in rpcNotifications

proc getInfo*(name: string): NimNode =
  if name notin rpcMethods:
    error(fmt"{name} is not registered")
  return rpcMethods[name]

macro getMethodParam*(name: static[string]): untyped =
  return getInfo(name)[0]

macro getMethodReturn*(name: static[string]): untyped =
  return getInfo(name)[1]

type
  ShouldCloseCheck* = proc (): bool
    ## Proc to check if a request should close

macro getMethodHandler*(name: static[string]): untyped =
  let info = getInfo(name)
  return nnkProcTy.newTree(
    nnkFormalParams.newTree(
      info[1],
      nnkIdentDefs.newTree(ident"handle", ident"RequestHandle", newEmptyNode()),
      nnkIdentDefs.newTree(ident"param", info[0], newEmptyNode()),
    ),
    nnkPragma.newTree(ident"gcsafe")
  )

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

export union
