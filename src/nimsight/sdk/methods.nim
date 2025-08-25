## This contains the built in defined methods

import std/options

import params, types

type
  RPCMessage*[P, R; isNotification: static[bool]] = object
    ## Define an RPC message with a input parameter `P` and return value `R`
    meth*: string
      ## The method used to identify the message

  RPCMethod*[P, R] = RPCMessage[P, R, true]
    ## Alias for [RPCMessage] that is a method

  RPCNotification*[P] = RPCMessage[P, void, false]
    ## Alias for [RPCMessage] that returns nothing (is a notification)
    # TODO: Is just checking for `void` return good enough to determine if its a notification?

proc defNotification[P](meth: string): RPCNotification[P] =
  ## Defines a new notification
  result.meth = meth

proc defMethod[P, R](meth: string): RPCMethod[P, R] =
  ## Defines a new method
  result.meth = meth

proc init*[P: not void, R, N](msg: RPCMessage[P, R, N], params: P): auto =
  ## Constructs a message for `msg`
  when N:
    NotificationMessage(`method`: msg.meth, params: some params.toJson())
  else:
    let id = nextRequestID()
    result = RequestMessage(`method`: msg.meth, params: params.toJson(), id: some id.toJson())

proc init*[R, N](msg: RPCMessage[void, R, N]): auto =
  ## Constructs a message. Specialisation that doesn't take parameters
  when N:
    NotificationMessage(`method`: msg.meth, params: none(JsonNode))
  else:
    let id = nextRequestID()
    result = RequestMessage(`method`: msg.meth, params: newJNull(), id: some id.toJson())


const
  # Client messages
  # > These are messages sent from the client to the server
  initialize* = defMethod[InitializeParams, InitializeResult]("initialize")
    ## Notification that the server should start initialising itself
  changedNotification* = defNotification[DidChangeTextDocumentParams]("textDocument/didChange")
    ## Notification that the content inside a document has changed
  openedNotification* = defNotification[DidOpenTextDocumentParams]("textDocument/didOpen")
    ## Notification that a new document has been opened
  savedNotification* = defNotification[DidSaveTextDocumentParams]("textDocument/didSave")
    ## Notification that the document has been saved
  closedNotification* = defNotification[DidCloseTextDocumentParams]("textDocument/didClose")
    ## Notification that the document has been closed
  symbolDefinition* = defMethod[TextDocumentPositionParams, Option[Location]]("textDocument/definition")
    ## Client is requesting where the symbol under the cursor is defined
  codeAction* = defMethod[CodeActionParams, seq[CodeAction]]("textDocument/codeAction")
    ## Client is requesting actions it can take
  documentSymbols* = defMethod[DocumentSymbolParams, seq[DocumentSymbol]]("textDocument/documentSymbol")
    ## Client is requesting all the symbols defined in a document
  selectionRange* = defMethod[SelectionRangeParams, seq[SelectionRange]]("textDocument/selectionRange")
    ## Client is requesting selection ranges e.g. ctrl-w in intellij
  windowShowMessage* = defNotification[ShowMessageparams]("window/showMessage")
    ## Tells the client to display a message to the user
  windowShowMessageRequest* = defMethod[
      ShowMessageRequestParams,
      Option[MessageActionItem]
    ]("window/showMessageRequest")
    ## Tells the client to display a message, along with options


  # Server messages
  # > These are messages sent from the server to the client
  initialized* = defNotification[InitializedParams]("initialized")
    ## Tells the client that the server has finished being initialised
  publishDiagnostics* = defNotification[PublishDiagnosticsParams]("textDocument/publishDiagnostics")
    ## Sends a list of diagnostics to the client to display
  logMessage* = defNotification[LogMessageParams]("window/logMessage")
    ## Send a message to the client to log to the console

  # Some custom internal messages
  # > These just get sent inside the server
  sendDiagnostics* = defNotification[DocumentURI]("extension/internal/sendDiagnostics")
    ## Custom method for making the server start sending diagnostics.
    ## Needed when client doesn't support pull diagnostics (kate)
  knockoff* = defNotification[void]("extension/internal/knockoff")
    ## Custom method for making an internal worker knock off from work

