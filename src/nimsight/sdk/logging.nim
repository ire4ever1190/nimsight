## Implements a logger that logs to the client

import std/logging

import types, protocol, params, methods

type
  LSPLogger = ref object of Logger
    ## Logger that logs to LSP client.

func toMessageType(level: Level): MessageType =
  ## Converts between LSP message level and Nim level
  const mapping: array[lvlDebug..lvlFatal, MessageType] = [
    lvlDebug: Log,
    lvlInfo: Info,
    lvlNotice: Info,
    lvlWarn: Warning,
    lvlError: Error,
    lvlFatal: Error
  ]
  return mapping[level]

func newLSPLogger*(): LSPLogger =
  result = LSPLogger(fmtStr: defaultFmtStr)

method log*(logger: LSPLogger, level: Level, args: varargs[string, `$`]) {.gcsafe.} =
  ## Logs to LSP console
  let msg = substituteLog(logger.fmtStr, level, args)
  sendNotification(logMessage, LogMessageParams(
    `type`: level.toMessageType(),
    message: msg
  ))

export logging
