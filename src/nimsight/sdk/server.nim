## This is the server. Its the heart of a language server and handles syncing files
## and sending/receving RPC messages

import std/[tables, json, jsonutils, strutils, logging, strformat, options, locks, typedthreads, isolation, atomics, sugar, paths, os]

import types, protocol, hooks, params, ./logging, ./files, ./customast, methods
import utils/locks

import utils/procmonitor

import threading/[channels, rwlock]

import pkg/anano

type
  Handler* = proc (handle: RequestHandle, x: JsonNode): Option[JsonNode] {.gcsafe.}
    ## Handler for a method. Uses JsonNode to perform type elision,
    ## gets converted into approiate types inside

  ResponseTable* = object
    ## Central location for waiting on responses to messages
    ## sent to the client
    cond: ConditionVar
      ## Condition which signals that a thread should check if
      ## it can read the response
    id: string
      ## ID that has been sent
    data: pointer
      ## Pointer containing the data

  WorkerThread = Thread[ptr Server]
    ## Thread that runs a worker for handling requests

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
    running: Atomic[bool]
      ## Tracks if the server is shutting down or not
    roots*: seq[Path]
      ## Workspace roots
    workers: seq[WorkerThread]
      ## All the spawned worker threads
    resultsLock*: RwLock
    results*: ResponseTable
    name*: string
    version*: string

  RequestHandle* = object
    ## Handle to a request. Used for getting information
    id: Option[string]
      ## ID of the request
    server*: ptr Server
      ## Pointer to the server. Please don't touch (I'm trusting you)

proc id(x: Message): Option[string] =
  ## Returns the ID of a message if it has one (Is a request, and ID is not null).
  ## Also normalises everything into a string
  if x of RequestMessage:
    let msg = RequestMessage(x)
    if msg.id.isSome() and msg.id.unsafeGet().kind != JNull:
      return some $msg.id.unsafeGet()

func id*(h: RequestHandle): Option[string] {.inline.} = h.id
# proc server*(x: RequestHandle): ptr Server {.inline.} = x.server

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

proc isRunning*(s: var Server): bool {.inline.} = s.running.load()

const NimblePkgVersion {.strdefine.} = "Unknown"
  ## Default to using the version defined by nimble

proc put*[T](table: var ResponseTable, id: string, data: sink T) =
  ## Sets the response value in the table
  table.id = id
  table.data = addr data
  table.cond.broadcast()
  # Data should move quick, just do a spinlock
  while not table.data.isNil: discard
  wasMoved(data)

proc get*[T](table: var ResponseTable, id: string, res: out T) =
  let x = addr table
  table.cond.wait(() => x[].id == id)
  res = move(cast[ptr T](table.data)[])
  table.data = nil
  release table.cond

proc get*[T](table: var ResponseTable, id: string): T =
  table.get(id, result)

proc sendRecvMessage(
  server: var Server,
  meth: static[string],
  params: getMethodParam(meth)
): getMethodReturn(meth) =
  ## Sends a message to the client, and then blocks until it reads a response
  let id = sendRequestMessage(
    meth,
    params
  )
  let data = server.results.get[:JsonNode](id)
  debug data.pretty()
  result.fromJson(data)

proc showMessageRequest*(
  server: var Server,
  message: string,
  typ: MessageType,
  actions: openArray[string]
): Option[string] =
  ## Sends a message to be shown to the client. Contains a list of actions that the
  ## user can click.
  ## Returns the action clicked, if they did
  let actions = collect:
    for action in actions:
      MessageActionItem(title: action)

  let resp = server.sendRecvMessage(
    windowShowMessageRequest,
    ShowMessageRequestParams(
      `type`: typ,
      message: message,
      actions: actions
    )
  )
  if resp.isSome():
    return some resp.unsafeGet().title

proc showMessageRequest*[T: enum](
  server: var Server,
  message: string,
  typ: MessageType,
  actions: typedesc[T]
): Option[T] =
  ## Typed version of [showMessageRequest]
  const options = collect:
    for choice in T:
      $choice
  let resp = server.showMessageRequest(message, typ, options)

  if resp.isSome():
    return parseEnum[T](resp.unsafeGet()).some()

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
    ReturnType = typeof(handler(RequestHandle(), default(ParamType)))
  proc inner(handle: RequestHandle, x: JsonNode): Option[JsonNode] {.stacktrace: off, gcsafe.} =
    ## Conversion of the JSON and catching any errors.
    ## TODO: Maybe use error return and then raises: []?
    let data = try:
        x.jsonTo(ParamType, JOptions(allowMissingKeys: true, allowExtraKeys: true))
      except CatchableError as e:
        raise (ref ServerError)(code: InvalidParams, msg: e.msg, data: x)
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
    except ServerError:
      raise
    except CatchableError as e:
      let entries = collect:
        for entry in e.getStacktraceEntries():
         fmt"{entry.filename}:{entry.line} {entry.procName}"
      raise (ref ServerError)(code: RequestFailed, msg: e.msg, data: %* entries)

  server.addHandler(event, inner)

proc newMessage*(event: static[string], params: getMethodParam(event)): Message =
  ## Constructs a message
  if event.isNotification:
    result = NotificationMessage(`method`: event, params: some params.toJson())
  else:
    let id = $genNanoID()
    result = RequestMessage(`method`: event, params: params.toJson(), id: some id.toJson())

proc meth(x: Message): string =
  case x
  of RequestMessage, NotificationMessage:
    x.`method`
  else:
    ""

proc params(x: Message): JsonNode =
  case x
  of RequestMessage: x.params
  of NotificationMessage:
    x.params.get(newJNull())
  else:
    newJNull()

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

proc updateFile*[T](h: RequestHandle, params: T) =
  h.server[].updateFile(params)

proc getRawFile*(h: RequestHandle, uri: DocumentURI, version = NoVersion): StoredFile =
  readWith h.server[].filesLock:
    return h.server[].files.rawGet(uri, version)

proc getFile*(h: RequestHandle, uri: DocumentURI, version = NoVersion): string =
  h.getRawFile(uri, version).content

proc parseFile*(h: RequestHandle, uri: DocumentURI, version = NoVersion): ParsedFile =
  readWith h.server[].filesLock:
    return h.server[].files.parseFile(uri)

proc workerThread(server: ptr Server) {.thread.} =
  ## Initialises a worker thread and then handles messages
  ## Implemented via a work stealing message queue
  # Initialise the worker.
  addHandler(newLSPLogger())
  # Start the worker loop
  while true:
    let request = server[].queue.recv()
    # Don't process if the server is shutting down
    if not server[].isRunning: break

    let id = request.id
    # TODO: Break this out into a generic handleMessage() proc
    # We are only reading this so it should be fine right??
    if request of ResponseMessage:
      let resp = ResponseMessage(request)
      server[].results.put(resp.id.getStr(), resp.`result`.unsafeGet)
      continue

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
    if id.isSome:
      writeWith server[].inProgressLock:
        server[].inProgress.del(id.unsafeGet())

proc spawnWorkers*(server: var Server, n: int) =
  ## Spawns `n` workers
  server.workers = newSeq[WorkerThread](n)
  for t in server.workers.mitems:
    t.createThread(workerThread, addr server)

proc queue*(server: var Server, msg: sink Message) =
  ## Queues a request to be handled by the server
  let id = msg.id
  if id.isSome():
    # Register request with server so it can be tracked
    server.updateRequestRunning($id.unsafeGet(), true)
  # Start running the message
  server.queue.send(unsafeIsolate(ensureMove(msg)))

proc shutdown*(server: var Server) =
  ## Shutdowns the server.
  ## - Signals that each worker should stop processing
  ## - Waits for all worker threads to finish
  ## Cannot be called on any worker thread (it will deadlock)
  # First notify all workers that they need to shutdown.
  server.running.store(false)
  writeWith server.inProgressLock:
    for running in server.inProgress.mvalues:
      running = false
  # Send a shutdown message. Each worker needs to read a message
  # so that it checks the running flag again.
  for _ in 0..server.workers.high:
    server.queue("shutdown".newMessage(""))
  # And make sure every thread stops.
  # Don't join the current thread
  joinThreads(server.workers)

proc cancel*(server: var Server, id: string) =
  ## Cancels a request in the server
  server.updateRequestRunning(id, false)

type Args = tuple[server: ptr Server, pid: int]
var t: Thread[Args]
proc checkProcess(args: Args) {.thread.} =
  ## Runs a check every 10 seconds that the process passed is still running.
  ## Shutdowns the server if it closes
  let (server, pid) = args
  while pid.isRunning():
    sleep 10 * 1000
  server[].shutdown()
  quit(QuitSuccess)

proc poll*(server: var Server) =
  ## Polls constantly for messages and handles responding.
  # initialize the workers.
  # TODO: Some jobs need some kind of affinity to maintain ordering.
  #       e.g. content change events NEED to be applied in order for incremental sync
  # TODO: Add way to configure number of workers
  server.spawnWorkers(3)

  while true:
    let request = readRequest()
    if request of RequestMessage:
      info "Calling method: ", RequestMessage(request).`method`

    # Few get special cased since we want them handled no matter what.
    # Rest get sent into worker queue
    case request.meth
    of "$/cancelRequest":
      # We special case handling $/cancelRequest since the worker queue
      # could be filled up which means the cancelRequest wouldn't get handled
      info "Cancelling ", request.params["id"]
      server.cancel($request.params["id"])
    of "shutdown":
      info "Shutting down"
      server.shutdown()
      request.respond(newJNull())
    of "exit":
      quit int(server.isRunning)
    else:
      # Spec says we should error if shutting down
      if server.isRunning:
        server.queue(request)
      else:
        request.respond(ServerError(code: InvalidRequest, msg: "Server is shutting down"))

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
  result.running.store(true)

  result.listen("initialize") do (r: RequestHandle, params: InitializeParams) -> InitializeResult:
    # Find what is supported depending on what handlers are registered.
    # Some manual capabilities will also need to be added
    result = InitializeResult(
      capabilities: ServerCapabilities(
        codeActionProvider: true,
        documentSymbolProvider: ServerCapabilities.documentSymbolProvider.init(true),
        textDocumentSync: ServerCapabilities.textDocumentSync.init(TextDocumentSyncOptions(
          openClose: true,
          change: Full
        )),
        selectionRangeProvider: true
      ),
      serverInfo: ServerInfo(
        name: r.server[].name,
        version: some(r.server[].version)
      )
    )
    # add all the roots
    r.server[].roots = params.folders

    # Add a listener for the parent process
    if params.processId.isSome:
      t.createThread(checkProcess, (r.server, params.processId.unsafeGet))

export hooks
