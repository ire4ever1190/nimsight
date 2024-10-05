## List of methods so that I don't misspell something

const
  initializeRequest* = "initialize"
  initialNotification* = "initialized"
  pubDiagnotisticsNotification* = "textDocument/publishDiagnostics"
  changedNotification* = "textDocument/didChange"
  openedNotification* = "textDocument/didOpen"
  symbolDefinition* = "textDocument/definition"
  logMessage* = "window/logMessage"
    ## Logs a message to the client
  codeAction* = "textDocument/codeAction"
    ## Client is requesting actions it can take
