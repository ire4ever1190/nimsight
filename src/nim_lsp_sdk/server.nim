import std/[tables, json, jsonutils, strutils, logging, strformat, options, locks, typedthreads, isolation]

import utils, types, protocol, hooks, params, ./logging, ./files

import threading/[channels, rwlock]

type
  Handler* = proc (handle: RequestHandle, x: JsonNode): Option[JsonNode] {.gcsafe.}
    ## Handler for a method. Uses JsonNode to perform type elision,
    ## gets converted into approiate types inside
  Server* = object
    listeners: Table[string, Handler]
    queue: Chan[Message]
      ## Queue of messages to process
    inProgressLock: RwLock
      ## Lock on the in progress table
    inProgress {.guard: inProgressLock.}: Table[string, bool]
      ## Table of request ID to whether they have been cancelled or not.
      ## i.e. if the value is false, then the request has been cancelled by the server.
      ## It is the request handlers just to check this on a regular basis.
    filesLock: RwLock
      ## Lock on [files]
    files {.guard: filesLock.}: Files
      ## Stores all the files in use by the server
    name*: string
    version*: string

  RequestHandle* = object
    ## Handle to a request. Used for getting information
    id*: Option[string]
      ## ID of the request
    server: ptr Server
      ## Pointer to the server. Please don't touch

proc id(x: Message): Option[string] =
  ## Returns the ID of a message if it has one (Is a request, and ID is not null).
  ## Also normalises everything into a string
  if x of RequestMessage:
    let msg = RequestMessage(x)
    if msg.id.isSome() and msg.id.unsafeGet().kind != JNull:
      return some $msg.id.unsafeGet()

proc initHandle*(id: Option[string], s: ptr Server): RequestHandle =
  RequestHandle(id: id, server: s)

proc isRunning*(r: RequestHandle): bool =
  ## Returns true if the request **should** still be running.
  ## i.e. if this is false then the request has been cancelled
  # Notifications can't really be cancelled
  if r.id.isNone(): return true
  # Check the table
  readWith r.server[].inProgressLock:
    # The ID should never be removed until the request is removed from the server
    return r.server[].inProgress[r.id.unsafeGet()]

const NimblePkgVersion {.strdefine.} = "Unknown"
  ## Default to using the version defined by nimble

proc addHandler(server: var Server, event: string, handler: Handler) =
  ## Internal method for adding handler.
  ## Should only be called in the main thread (We don't lock the listeners)
  # if event notin server.listeners:
    # server.listeners[event] = @[]
  server.listeners[event] = handler


proc listen*(server: var Server, event: static[string], handler: getMethodHandler(event)) =
  ## Adds a handler for an event
  type
    ParamType = getMethodParam(event)
    ReturnType = typeof(handler(RequestHandle(), ParamType()))
  proc inner(handle: RequestHandle, x: JsonNode): Option[JsonNode] {.stacktrace: off, gcsafe.} =
    ## Conversion of the JSON and catching any errors.
    ## TODO: Maybe use error return and then raises: []?
    let data = try:
        x.jsonTo(ParamType, JOptions(allowMissingKeys: true, allowExtraKeys: true))
      except CatchableError as e:
        raise (ref ServerError)(code: InvalidParams, msg: e.msg)
    try:
      when ReturnType is not void:
        let ret = handler(handle, data)
        {.gcsafe.}:
          return some ret.toJson()
      elif event.isNotification:
        handler(handle, data)
        return none(JsonNode)
      else:
        handler(handle, data)
        return some newJNull()
    except CatchableError as e:
      raise (ref ServerError)(code: RequestFailed, msg: e.msg)

  server.addHandler(event, inner)

proc meth(x: Message): string =
  if x of RequestMessage:
    return RequestMessage(x).`method`
  elif x of NotificationMessage:
    return NotificationMessage(x).`method`
  return ""

proc params(x: Message): JsonNode =
  if x of RequestMessage:
    return RequestMessage(x).params
  elif x of NotificationMessage:
    return NotificationMessage(x).params.get(newJNull())
  return newJNull()

proc updateRequestRunning(s: var Server, id: string, val: bool) =
  ## Updates the request running statusmi
  writeWith s.inProgressLock:
    s.inProgress[id] = val

proc updateFile(s: var Server, params: DidChangeTextDocumentParams) =
  ## Updates file cache with updates
  let doc = params.textDocument
  assert params.contentChanges.len == 1, "Only full updates are supported"
  writeWith s.filesLock:
    for change in params.contentChanges:
      s.files.put(doc.uri, change.text, doc.version)

proc updateFile*(s: var Server, params: DidOpenTextDocumentParams) =
  ## Updates file cache with an open item
  let doc = params.textDocument
  writeWith s.filesLock:
    s.files.put(doc.uri, doc.text, doc.version)

proc getFile*(h: RequestHandle, uri: string, version = NoVersion): string =
  readWith h.server[].filesLock:
    return h.server[].files[uri, version]


proc workerThread(server: ptr Server) {.thread.} =
  ## Initialises a worker thread and then handles messages
  ## Implemented via a work stealing message queue
  # Initialise the worker.
  addHandler(newLSPLogger())
  # Start the worker loop
  while true:
    let request = server[].queue.recv()
    let id = request.id
    # TODO: Break this out into a generic handleMessage() proc
    # We are only reading this so it should be fine right??
    if request.meth in server[].listeners:
      let
        handler = server[].listeners[request.meth]
        handle = initHandle(id, server)
      try:
        let returnVal = handler(handle, request.params)
        if returnVal.isSome():
          request.respond(returnVal.unsafeGet())
      except ServerError as e:
        debug("Failed: ", e.msg)
        request.respond(e[])
    else:
      request.respond(ServerError(code: MethodNotFound, msg: fmt"Nothing to handle {request.meth}"))
    # Remove the request from the in-progress list.
    # Stops it massively growing for no reason
    if id.isSome:
      writeWith server[].inProgressLock:
        server[].inProgress.del(id.unsafeGet())


proc poll*(server: var Server) =
  ## Polls constantly for messages and handles responding.
  # initialize the workers.
  # TODO: Some jobs need some kind of affinity to maintain ordering.
  #       e.g. content change events NEED to be applied in order for incremental sync
  # TODO: Add way to configure number of workers
  var threads: array[2, Thread[ptr Server]]
  for t in threads.mitems:
    t.createThread(workerThread, addr server)

  while true:
    let request = readRequest()
    let id = request.id
    if request of RequestMessage:
      info "Recieved method: ", RequestMessage(request).`method`

    # We special case handling $/cancelRequest since the worker queue
    # could be filled up which means the cancelRequest wouldn't get handled
    if request of NotificationMessage and NotificationMessage(request).`method` == "$/cancelRequest":
      info "Cancelling ", request.params["id"]
      server.updateRequestRunning($request.params["id"], false)
    else:
      if id.isSome():
        # Add to in-progress
        server.updateRequestRunning($id.unsafeGet(), true)

      server.queue.send(unsafeIsolate(ensureMove(request)))




proc initServer*(name: string, version = NimblePkgVersion): Server =
  ## Initialises the server. Should be called since it registers
  ## some needed handlers to make helpers work
  result = Server(
    name: name,
    inProgressLock: createRwLock(),
    version: version,
    queue: newChan[Message](),
    filesLock: createRwLock(),
    files: initFiles(20) # TODO: Make this configurable
  )

  result.listen("initialize") do (r: RequestHandle, params: InitializeParams) -> InitializeResult:
    # Find what is supported depending on what handlers are registered.
    # Some manual capabilities will also need to be added
    InitializeResult(
      capabilities: ServerCapabilities(
        codeActionProvider: true,
        documentSymbolProvider: ServerCapabilities.documentSymbolProvider.init(true),
        textDocumentSync: ServerCapabilities.textDocumentSync.init(TextDocumentSyncOptions(
          openClose: true,
          change: Full
        ))
      ),
      serverInfo: ServerInfo(
        name: r.server[].name,
        version: some(r.server[].version)
      )
    )

export hooks
