import std/[options, json, tables, hashes, paths, strutils]

import utils

type
  ErrorCode* = enum
    ## [See spec](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#errorCodes)
    RequestFailed = -32803
      ## Request failed, but everything the client sent was correct
    ServerCancelled = -32802
    ContentModified = -32801
    RequestCancelled = -32800
    # JSONRPC error codes
    ParseError = -32700
    InternalError = -32603
    InvalidParams = -32602
    MethodNotFound = -32601
    InvalidRequest = -32600
    # Start of LSP error codes
    ServerNotInitialized = -32002
    UnknownErrorCode =  -32001

  ChangeAnnotationIdentifier = string

  Message* = ref object of RootObj
    ## [See spec](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#message)
    jsonrpc*: string = "2.0"

  PartialResultToken* = JsonNode
    ## Field used to indicate whether a partial result can be used

  SupportsPartialResults* = concept
    ## Type supports partial results
    proc partialResultToken(): Option[PartialResultToken]

  PartialResultParams* = object
    ## [See spec](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#partialResultParams)
    partialResultToken: Option[PartialResultToken]

  RequestMessage* = ref object of Message
    ## Request from client to server
    ##
    ## [See spec](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#requestMessage)
    id*: Option[JsonNode]
    `method`*: string
    params*: JsonNode

  NotificationMessage* = ref object of Message
    ## Event sent from client to server
    ##
    ## [See spec](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#notificationMessage)
    `method`*: string
    params*: Option[JsonNode]

  ResponseMessage* = ref object of Message
    ## Response from server to client
    ##
    ## [See spec](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#responseMessage)
    id*: JsonNode
    # TODO: Make variant object
    `result`*: Option[JsonNode]
    error*: Option[ResponseError]

  ResponseError* = object
    ## [See spec](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#responseError)
    code*: ErrorCode
    message*: string
    data*: Option[JsonNode]

  ShowMessageParams* = object
    `type`*: MessageType
    message*: string

  DocumentURI* = distinct string
  Position* = object
    ## Position in a doucment.
    ##
    ## [See spec](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#position)
    line*: uint
      ## Position in the document (0 indexed)
    character*: uint
      ## character in the line (0 indexed). Defaults to line length if longer than the line

  PositionEncodingKind = enum
    ## [See spec](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#positionEncodingKind)
    UTF8 = "utf-8"
    UTF16 = "utf-16"
    UTF32 = "utf-32"

  Range* = object
    ## Specifies a selection (Exclusive of end)
    ##
    ## [See spec](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#range)
    start*: Position
    `end`*: Position

  TextDocumentItem* = object
    ## Specifies a document. This is used for transferring a file to the server
    ##
    ## [See spec](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#textDocumentItem)
    uri*: DocumentURI
    languageId*: string
    version*: int
    text*: string

  TextDocumentIdentifier* = ref object of RootObj
    ## Used to refer to a document
    ##
    ## [See spec](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#textDocumentIdentifier)
    uri*: DocumentURI

  VersionedTextDocumentIdentifier* = ref object of TextDocumentIdentifier
    ## Used to refer to a specific version of a document
    ##
    ## [See spec](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#versionedTextDocumentIdentifier)
    version*: int

  OptionalVersionedTextDocumentIdentifier = object of TextDocumentIdentifier
    ## Used to refer to a specific version of a document.
    ## Expect the version can be null which means the disk verison is the latest.
    ##
    ## [See spec](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#optionalVersionedTextDocumentIdentifier)
    version: Option[int]

  TextDocumentPositionParams* = object
    ## Selects a position inside a doucment
    ##
    ## [See spec](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#textDocumentPositionParams)
    textDocument*: TextDocumentIdentifier
    position*: Position

  DocumentFilter* = object
    ## .. Info:: At least one option must be selected
    ##
    ## [See spec](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#documentFilter)
    language*: Option[string]
    scheme*: Option[string]
    pattern*: Option[string]

  DocumentSelector* = seq[DocumentFilter]

  TextEdit* = ref object of RootObj
    ## Edit to update text in a document
    ##
    ## [See spec](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#textEdit)
    range*: Range
    newText*: string

  ChangeAnnotation* = object
    ## Used to provide a dialog for an edit
    ##
    ## [See spec](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#changeAnnotation)
    label*: string
    needsConfirmation*: bool
    description*: Option[string]

  AnnotatedTextEdit* = ref object of TextEdit
    ## [See spec](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#annotatedTextEdit)
    annotationId*: string

  RootEditObj = ref object of RootObj

  TextDocumentEdit* = ref object of RootEditObj
    ## Describes a list of changes to apply to a document.
    ##
    ## [See spec](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#textDocumentEdit)
    textDocument*: OptionalVersionedTextDocumentIdentifier
    edits: seq[TextEdit]

  Location* = object
    ## Location inside a file
    ##
    ## [See spec](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#location)
    uri*: DocumentURI
    range*: Range

  LocationLink* = object
    ## Link between two locations.
    ##
    ## [See spec](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#locationLink)
    originSelectionRange*: Option[Range]
    targetUri*: DocumentURI
    targetRange*: Range
    targetSelectionRange*: Range

  DiagnosticSeverity* = enum
    ## [See spec](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#diagnosticSeverity)
    Error = 1
    Warning = 2
    Information = 3
    Hint = 4

  MessageType* = enum
    Error = 1
    Warning = 2
    Info = 3
    Log = 4
    Debug = 5

  DiagnosticTag* = enum
    ## [See spec](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#diagnosticTag)
    Unnecessary = 1
    Deprecated = 2

  DiagnosticRelatedInformation* = object
    ## [See spec](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#diagnosticRelatedInformation)
    location: Location
    message: string

  CodeDescription* = object
    ## [See spec](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#codeDescription)
    href: DocumentURI

  Diagnostic* = object
    ## Like a warning or error in the document
    ##
    ## [See spec](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#diagnostic)
    range*: Range
    severity*: Option[DiagnosticSeverity]
    code*: Option[string]
    codeDescription*: Option[CodeDescription]
    source*: Option[string]
    message*: string
    tags*: Option[seq[DiagnosticTag]]
    relatedInformation*: Option[seq[DiagnosticRelatedInformation]]
    data*: Option[JsonNode] # Maybe make this generic?

  Command* = object
    ## Command to show in the UI
    ##
    ## [See spec](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#command)
    title*: string
    command*: string
    arguments*: Option[JsonNode]

  MarkupKind* = enum
    ## [See spec](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#markupContent)
    PlainText = "plaintext"
    Markdown = "markdown"

  MarkupContent* = object
    ## [See spec](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#markupContentInnerDefinition)
    kind*: MarkupKind
    value*: string

  MarkdownClientCapabilities* = object
    ## [See spec](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#markdownClientCapabilities)
    parser*: string
    version*: Option[string]
    allowedTags*: Option[seq[string]]

  CreateFileOptions* = object
    ## [See spec](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#createFileOptions)
    overwrite*: Option[bool]
    ignoreIfExists*: Option[bool]

  CreateFile* = ref object of RootEditObj
    ## [See spec](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#createFile)
    kind* = "create"
    uri*: DocumentUri
    options*: CreateFileOptions
    annotationId*: ChangeAnnotationIdentifier

  RenameFileOptions* = object
    ## [See spec](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#renameFileOptions)
    overwrite: Option[bool]
    ignoreIfExists*: Option[bool]

  RenameFile* = ref object of RootEditObj
    ## [See spec](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#renameFile)
    kind* = "rename"
    oldUri*: DocumentUri
    newUri*: DocumentUri
    options*: Option[RenameFileOptions]
    annotationid*: ChangeAnnotationIdentifier

  DeleteFileOptions* = object
    ## [See spec](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#deleteFileOptions)
    recursive*: Option[bool]
    ignoreIfNotExists*: Option[bool]

  DeleteFile* = ref object of RootEditObj
    ## [See spec](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#deleteFile)
    kind* = "delete"
    uri*: DocumentUri
    options: Option[DeleteFileOptions]
    annotationId*: Option[ChangeAnnotationIdentifier]

  WorkspaceEdit* = object
    ## [See spec](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#workspaceEdit)
    changes*: Option[Table[DocumentURI, seq[TextEdit]]]
    documentChanges*: Option[seq[RootEditObj]]
    changeAnnotations*: Option[Table[string, ChangeAnnotation]]

  ChangeAnnotationSupport* = object
    groupsOnLabel*: Option[bool]

  ResourceOperationKind* = enum
    ## [See spec](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#resourceOperationKind)
    Create = "create"
    Rename = "rename"
    Delete = "delete"

  FailureHandlingKind* = enum
    ## [See spec](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#failureHandlingKind)
    Abort = "abort"
    Transactional = "transactional"
    TextOnlyTransactional = "textOnlyTransactional"
    Undo = "undo"

  WorkspaceEditClientCapabilities* = object
    ## [See spec](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#workspaceEditClientCapabilities)
    documentChanges*: Option[bool]
    resourceOperations*: Option[seq[ResourceOperationKind]]
    failureHandling*: Option[FailureHandlingKind]
    normalizesLineEndings*: Option[bool]
    changeAnnotationSupport*: Option[ChangeAnnotationSupport]

  WorkDoneProgressBegin* = object
    ## [See spec](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#failureHandlingKind)
    kind = "begin"
    title*: string
    cancellable*: Option[bool]
    message*: Option[string]
    percentage*: Option[uint]

  WorkDoneProgressReport* = object
    ## [See spec](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#workDoneProgressReport)
    kind = "report"
    cancellable*: Option[bool]
    message*:  Option[string]
    percentage*: Option[uint]

  WorkDoneProgressEnd* = object
    ## [See spec](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#workDoneProgressEnd)
    kind = "end"
    message: Option[string]

  WorkDoneProgressParams* = ref object of RootObj
    ## [See spec](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#workDoneProgressParams)
    workDoneToken*: JsonNode # Int or string

  TraceValue* = enum
    Off = "off"
    Messages = "messages"
    Verbose = "verbose"

  ClientInfo* = object
    ## Information about the connecting client
    name*: string
    version*: Option[string]

  ServerInfo* = object
    name*: string
    version*: Option[string]

  InitializeResult* = object
    capabilities*: ServerCapabilities
    serverInfo*: ServerInfo

  WorkspaceFolder* = object
    uri*: DocumentURI
    name*: string

  TextDocumentContentChangeEvent* = object
    ## [See spec](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#textDocumentContentChangeEvent)
    case incremental*: bool
    of true:
      range*: Range
    else: discard
    text*: string

  CodeActionKind* = object
    ## [See spec](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#codeActionKind)
    Empty = ""
    QuickFix = "quickfix"
    Refactor = "refactor"
    Extract = "refactor.extract"
    Inline = "refactor.inline"
    Rewrite = "refactor.rewrite"
    Source = "source"
    OrganiseImports = "source.organizeImports"
    SourceFixAll = "source.fixAll"

  WorkDoneProgressOptions = ref object of RootObj
    workDoneProgress: bool


  CodeActionOptions* = ref object of WorkDoneProgressOptions
    codeActionKinds*: seq[CodeActionKind]
    resolveProvider*: bool

  DocumentSymbolOptions* = object
    ## [See Spec](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#documentSymbolOptions)
    label*: Option[string]

  TextDocumentSyncKind* = enum
    ## [See Spec](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#textDocumentSyncKind)
    None
    Full
    Incremental

  TextDocumentSyncOptions* = object
    openClose*: bool
    change*: TextDocumentSyncKind

  ServerCapabilities* = object
    codeActionProvider*: bool
    documentSymbolProvider*: Union[(bool, DocumentSymbolOptions)]
    textDocumentSync*: Union[(bool, TextDocumentSyncOptions)]

  ClientCapabilities* = object

type
  ServerError* = object of CatchableError
    code*: ErrorCode

func `<`*(a, b: Position): bool =
  return a.line < b.line or  (a.line == b.line and a.character < b.character)

proc hash*(x: DocumentURI): Hash {.borrow.}
proc `==`*(a, b: DocumentURI): bool {.borrow.}
proc `$`*(x: DocumentURI): string {.borrow.}

func path*(x: DocumentURI): Path =
    ## Converts to a path
    result = x.string.replace("file://", "").Path
