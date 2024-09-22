import std/[strscans, strutils, syncio, json, jsonutils, options, strformat, tables]
import std/macros
import std/logging
import nim_lsp_sdk/nim_check

import nim_lsp_sdk/types

var fileLog = newFileLogger("/tmp/errors.log")
addHandler(fileLog)

proc to[T](r: RequestMessage, _: typedesc[T]): T =
  ## Parses the params into type T

proc writeHeader(f: File, name: string, val: string) =
  f.write(&"{name}: {val}\r\n")

type
  RequestError = object of CatchableError
    request: RequestMessage
  ServerError = object of CatchableError
    code: ErrorCode



proc writeResponse(respBody: string) =
  stdout.writeHeader("Content-Length", $respBody.len)
  stdout.write("\r\n")
  stdout.write(respBody)
  stdout.flushFile()

proc respond[T](r: RequestMessage, resp: T) =
  ## Responds to a request
  let resp = ResponseMessage(
    jsonrpc: "2.0",
    id: r.id.get(),
    `result`: some resp.toJson()
  ).toJson()
  resp.delete("error")

  let respBody = $resp
  respBody.writeResponse()
  debug("Written: \n" & respBody)

proc respond(r: NotificationMessage) =
  ## We need to send something
  let resp = ResponseMessage(
    jsonrpc: "2.0",
    id: newJNull(),
    `result`: some newJNull()
  ).toJson()
  resp.delete("error")

  let respBody = $resp
  respBody.writeResponse()
  debug("Written: \n" & respBody)

proc respond(r: JsonNode, e: ServerError) =
  let resp = ResponseMessage(
    jsonrpc: "2.0",
    id: r{"id"},
    error: some ResponseError(
      code: e.code,
      message: e.msg
    )
  ).toJson()
  resp.delete("result")

  let respBody = $resp
  respBody.writeResponse()
  debug("Written: \n" & respBody)

proc sendNotificiation(meth: string, params: JsonNode) =
  let obj = NotificationMessage(
    `method`: meth,
    params: some params
  )
  let reqBody = $obj.toJson()
  reqBody.writeResponse()

var
  listeners: Table[string, proc (request: RequestMessage): JsonNode]
  notificationHandlers: Table[string, proc (request: NotificationMessage)]

proc readRequest(): JsonNode =
  ## Reads the JSON body that the client has sent
  # First we want to find the Content-Length heade
  var
    line: string
    contentLength = 0
  while (stdin.readLine(line) and line != ""):
    let (ok, name, val) = line.scanTuple("$+:$s$i")
    if ok and name.toLowerAscii() == "content-length":
      contentLength = val
      break
  # Read the empty line
  discard stdin.readLine()
  # Now read the body
  var body = newString(contentLength)
  assert stdin.readChars(body) == contentLength
  debug("Read: \n" & body)
  return body.parseJson()


macro getMethodParam(meth: static[string]): untyped =
  ## Returns an ident for what a method expects
  result = case meth
  of "initialize": ident"InitializeParams"
  else: ident"JsonNode"

macro getMethodResult(meth: static[string]): untyped =
  ## Returns an ident for what a method should return
  result = case meth
  of "initialize": ident"InitializeResult"
  else: ident"void"



proc listen(meth: static[string], handler: proc (param: getMethodParam(meth)): getMethodResult(meth)) =
  proc wrapper(request: RequestMessage): JsonNode =
    let param = try:
        request.params.jsonTo(getMethodParam(meth), JOptions(allowMissingKeys: true, allowExtraKeys: true))
      except ValueError as e:
          raise (ref RequestError)(msg: e.msg, request: request)
    let resp = handler(param)
    resp.toJson()
  listeners[meth] = wrapper

"initialize".listen() do (x: InitializeParams) -> InitializeResult:
  result = InitializeResult(serverInfo: ServerInfo(
    name: "Nim checker",
    version: some "1.0.0"
  ))

while true:
  let req = readRequest()
  if "method" in req: # Its a request
    let meth = req["method"].getStr()
    debug("Dispatching: " & req["method"].getStr())
    try:
      if "id" in req: # Its a Request Message
        let requestMsg = req.jsonTo(RequestMessage)
        if requestMsg.`method` in listeners:
          requestMsg.respond(listeners[requestMsg.`method`](requestMsg))
        else:
          raise (ref ServerError)(code: MethodNotFound, msg: "I have not implemented " & requestMsg.`method`)

      else: # Notification
        let notification = req.jsonTo(NotificationMessage)
        if notification.`method` in ["textDocument/didOpen", "textDocument/didChange"]:
          # Just going to chuck this here for nows
          sendNotificiation("textDocument/publishDiagnostics", PublishDiagnosticsParams(
            uri: notification.params.unsafeGet()["textDocument"]["uri"].getStr(),
            version: some notification.params.unsafeGet()["textDocument"]["version"].getInt(),
            diagnostics: getErrors(notification.params.unsafeGet()["textDocument"]["uri"].getStr().replace("file://", ""))
          ).toJson())
        notification.respond()
    except RequestError as e:
      debug("Failed with request: " & e.msg)
      debug($ e.request.params.pretty())
    except ServerError as e:
      req.respond(e[])
  else: # Its a response
    let err = req.jsonTo(ResponseMessage, JOptions(allowMissingKeys: true))
    if err.error.isSome():
      let e = err.error.unsafeGet()
      raise (ref ServerError)(code: e.code, msg: e.message & ": " & $e.code)
