import std/[macrocache, macros, strformat, paths]

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


func `/`*(a: Path, b: static[string]): Path = a / Path(b)

