## This is the server. Its the heart of a language server and handles syncing files
## and sending/receving RPC messages

import std/[tables, json, jsonutils, strutils, logging, strformat, options, locks, typedthreads, isolation, atomics, sugar, paths, os]

import types, protocol, hooks, params, ./logging, methods

import utils, methods

import threading/[channels, rwlock]

import pkg/jaysonrpc

type
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
    queue*, orderedQueue: Chan[string]
      ## Queue of messages to process.
      ## We also have an ordered queue when when we don't want to reorder requests
    roots*: seq[Path]
      ## Workspace roots
    workers: seq[WorkerThread]
      ## All the spawned worker threads
    resultsLock*: RwLock
    results*: ResponseTable
    name*: string
    version*: string
    executor: Executor[JsonNode, ptr Server]

  NimContext* = Context[ptr Server]

# Extra error codes for LSP
const
  RequestCancelled* = RPCErrorCode(-32800)

proc id(x: Message): Option[string] =
  ## Returns the ID of a message if it has one (Is a request, and ID is not null).
  ## Also normalises everything into a string
  if x of RequestMessage:
    let msg = RequestMessage(x)
    if msg.id.isSome() and msg.id.unsafeGet().kind != JNull:
      return some $msg.id.unsafeGet()

func isRunning*(server: var Server): bool =
  ## Checks if server is still considered running
  return server.executor.isRunning()

const NimblePkgVersion {.strdefine.} = "Unknown"
  ## Nimble defines this when building a project. Default the server
  ## to this version

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

proc sendRecvMessage[P, R](
  server: var Server,
  meth: RPCMethod[P, R],
  params: P
): R =
  ## Sends a message to the client, and then blocks until it reads a response
  let id = $sendRequestMessage(
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

proc on*(server: var Server, meth: string, handler: proc) =
  ## Adds a handler for an event
  server.executor.on(meth, handler)


proc handleCalls(rpc: Executor[JsonNode, ptr Server], payload: string, server: ptr Server) =
  ## Executes all the calls synchronously and sends a response
  ## LSP forbids batch calls, so there will never be more than 1
  let calls = rpc.getCalls(payload, server)
  let responses = collect:
    for call in calls:
      call()
  let response = calls.dump(responses)
  response.map(writeResponse)
template makeWorkerThread(queue: untyped): untyped =
  proc workerThread(server: ptr Server) {.nimcall, thread.} =
    ## Initialises a worker thread and then handles messages
    ## Implemented via a work stealing message queue
    # Initialise the worker.
    addHandler(newLSPLogger())
    let rpc = server[].executor
    # Start the worker loop
    info "Starting worker thread for " & astToStr(queue)
    while true:
      let request = server[].queue.recv()
      # Don't process if the server is shutting down
      if not server[].isRunning:
        break

      rpc.handleCalls(request, server)
  workerThread


proc spawnWorkers*(server: var Server, n: int) =
  ## Spawns `n` workers
  server.workers = newSeq[WorkerThread](n)
  for i in 0 ..< server.workers.len - 1:
    server.workers[i].createThread(makeWorkerThread(queue), addr server)
  server.workers[^1].createThread(makeWorkerThread(orderedQueue), addr server)

proc shutdown*(server: var Server) =
  ## Shutdowns the server.
  ## - Signals that each worker should stop processing
  ## - Waits for all worker threads to finish
  ## Cannot be called on any worker thread (it will deadlock)

  # Everything start gracefully shutting down
  server.executor.shutdown()

  # Send a shutdown message. Each worker needs to read a message
  # so that it checks the running flag again.
  # for _ in 0..server.workers.high:
    # server.queue(knockoff.init())
  # And make sure every thread stops.
  # Don't join the current thread
  joinThreads(server.workers)

type Args = tuple[server: ptr Server, pid: int]
var t: Thread[Args]
proc checkProcess(args: Args) {.thread.} =
  ## Runs a check every 10 seconds that the process passed is still running.
  ## Shutdowns the server if it closes.
  ## This is used to make sure we close after the parent editor closes
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
  # Some methods we want to handle without needing the queue. Mainly so they can be handled
  # if all the workers and full and server is going haywire
  # List them here, and execute here instead of sending them to workers
  const handleFirst = [
    "$/cancelRequest",
    "shutdown",
    "exit"
  ]

  # These are requests that we shouldn't run out of order from the client.
  # They get placed in a special queue where everything is ordered
  const requireOrdering = [
    # We want to make sure updates happen in order so we are only running checks on the latest
    changedNotification.meth,
    openedNotification.meth,
    savedNotification.meth
  ]

  while true:
    let request = readPayload()

    # Very wasteful, but simpliest thing to do
    let meth = request{"method"}.getStr()
    if meth in handleFirst:
      server.executor.handleCalls($ request, addr server)
    elif meth in requireOrdering:
      server.orderedQueue.send($ request)
    else:
      server.queue.send($ request)

func folders*(rootUri: Option[DocumentURI], rootPath: Option[Path], workspaceFolders: Option[seq[WorkspaceFolder]]): seq[Path] =
  ## Returns all the paths that are in the intialisation
  # Root URI has precedence over rootPath
  if rootUri.isSome():
    result &= rootUri.unsafeGet().path
  elif rootPath.isSome():
    result &= rootPath.unsafeGet()

  for folder in workspaceFolders.get(@[]):
    result &= folder.uri.path


proc initServer*(name: string, version = NimblePkgVersion): Server =
  ## Initialises the server. Should be called since it registers
  ## some needed handlers to make helpers work
  result = Server(
    name: name,
    version: version,
    executor: initExecutor[JsonNode, ptr Server](),
    queue: newChan[string](),
    orderedQueue: newChan[string](),
  )

  result.on("initialize") do (
      ctx: NimContext,
      processId: Option[int],
      rootPath: Option[Path],
      rootUri: Option[DocumentURI],
      workspaceFolders: Option[seq[WorkspaceFolder]]
    ) -> InitializeResult:
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
        name: ctx.data[].name,
        version: some(ctx.data[].version)
      )
    )
    # add all the roots
    ctx.data[].roots = folders(rootUri, rootPath, workspaceFolders)

    # Add a listener for the parent process
    if processId.isSome:
      t.createThread(checkProcess, (ctx.data, processId.unsafeGet))

export hooks, jaysonrpc
