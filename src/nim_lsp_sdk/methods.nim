## List of methods so that I don't misspell something

const
  initializeRequest* = "initialize"
  initialNotification* = "initialized"
  pubDiagnotisticsNotification* = "textDocument/publishDiagnostics"
  changedNotification* = "textDocument/didChange"
  openedNotification* = "textDocument/didOpen"
  savedNotification* = "textDocument/didSave"
  symbolDefinition* = "textDocument/definition"
  logMessage* = "window/logMessage"
    ## Logs a message to the client
  codeAction* = "textDocument/codeAction"
    ## Client is requesting actions it can take
  documentSymbols* = "textDocument/documentSymbol"
  sendDiagnostics* = "extension/sendDiagnostics"
    ## Custom method for making the server start sending diagnostics.
    ## Needed when client doesn't support pull diagnostics (kate)
  selectionRange* = "textDocument/selectionRange"

  windowShowMessage* = "window/showMessage"
  windowShowMessageRequest* = "window/showMessageRequest"
