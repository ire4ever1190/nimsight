## Contains type definitions for the methods

import std/[options, json, paths]

import utils

import types

type
  InitializeParams* = ref object of WorkDoneProgressParams
    ## Initial message sent by client
    ##
    ## [See spec](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#initializeParams)
    processId*: Option[int]
    clientInfo*: Option[ClientInfo]
    locale*: Option[string]
    rootPath*: Option[Path]
    rootUri*: Option[DocumentUri]
    initializationOptions*: Option[JsonNode]
    capabilities*: ClientCapabilities
    trace*: Option[TraceValue]
    workspaceFolders*: Option[seq[WorkspaceFolder]]

  PublishDiagnosticsParams* = object
    ## [See spec](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#publishDiagnosticsParams)
    uri*: DocumentUri
    version*: Option[int]
    diagnostics*: seq[Diagnostic]

  DidOpenTextDocumentParams* = object
    textDocument*: TextDocumentItem

  DidChangeTextDocumentParams* = object
    textDocument*: VersionedTextDocumentIdentifier
    contentChanges*: seq[TextDocumentContentChangeEvent]

  LogMessageParams* = object
    ## [See spec](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#window_logMessage)
    `type`*: MessageType
    message*: string

  CodeActionTriggerKind* = enum
    ## [See spec](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#codeActionTriggerKind)
    Invoked = 1
    Automatic = 2

  CodeActionContext* = object
    ## [See spec](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#codeActionContext)
    diagnostics*: seq[Diagnostic]
    only: Option[seq[CodeActionKind]]
    triggerKind*: CodeActionTriggerKind

  CodeActionParams* = ref object # TODO: Make a mixin macro for crap like this
    ## [See spec](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#codeActionParams)
    textDocument*: TextDocumentIdentifier
    range*: Range
    context*: CodeActionContext

  Command* = object
    ## [See spec](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#command)
    title: string
    command: string
    arguments: Option[seq[JsonNode]]

  CodeAction* = object
    title*: string
    kind*: Option[CodeActionKind]
    diagnostics*: Option[seq[Diagnostic]]
    isPreferred: Option[bool]
    disabled: Option[tuple[reason: string]]
    edit*: Option[WorkspaceEdit]
    command: Option[Command]
    data*: Option[JsonNode]

  ShowMessageRequestParams* = object
    `type`*: MessageType
    message*: string
    actions*: seq[MessageActionItem]

  SelectionRangeParams* = object of mixed(PartialResultParams)
    textDocument*: TextDocumentIdentifier
    positions*: seq[Position]

  DocumentSymbolParams* = object of mixed(PartialResultParams)
    textDocument*: TextDocumentIdentifier
  DidSaveTextDocumentParams* = object
    textDocument*: TextDocumentIdentifier
  InitializedParams* = object

  InitializeResult* = object
    capabilities*: ServerCapabilities
    serverInfo*: ServerInfo

  TextDocumentPositionParams* = object
    ## Selects a position inside a doucment
    ##
    ## [See spec](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#textDocumentPositionParams)
    textDocument*: TextDocumentIdentifier
    position*: Position

func folders*(params: InitializeParams): seq[Path] =
  ## Returns all the paths that are in the intialisation
  # Root URI has precedence over rootPath
  if params.rootUri.isSome():
    result &= params.rootUri.unsafeGet().path
  elif params.rootPath.isSome():
    result &= params.rootPath.unsafeGet()

  for folder in params.workspaceFolders.get(@[]):
    result &= folder.uri.path
