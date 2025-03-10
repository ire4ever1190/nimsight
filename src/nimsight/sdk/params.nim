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

  SymbolKind* = enum
    ## [See spec](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#symbolKind)
    File = 1
    Module = 2
    Namespace = 3
    Package = 4
    Class = 5
    Method = 6
    Property = 7
    Field = 8
    Constructor = 9
    Enum = 10
    Interface = 11
    Function = 12
    Variable = 13
    Constant = 14
    String = 15
    Number = 16
    Boolean = 17
    Array = 18
    Object = 19
    Key = 20
    Null = 21
    EnumMember = 22
    Struct = 23
    Event = 24
    Operator = 25
    TypeParameter = 26

  SymbolTag* = enum
    Deprecated

  ShowMessageRequestParams* = object
    `type`*: MessageType
    message*: string
    actions*: seq[MessageActionItem]

  DocumentSymbol* = ref object
    ## [See spec](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#documentSymbol)
    name*: string
    detail*: Option[string]
    kind*: SymbolKind
    tags*: Option[SymbolTag]
    range*: Range
    selectionRange*: Range
    children*: seq[DocumentSymbol]

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
