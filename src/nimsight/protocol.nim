## Handles communication between the client/server
import std/[json, jsonutils, options, strscans, strutils, strformat, locks]
import types, utils, hooks, methods

import params
import pkg/anano

proc readPayload*(): JsonNode =
  ## Reads the JSON body that the client has sent
  # First we want to find the Content-Length heade
  try:
    var
      line: string
      contentLength = 0
    while (stdin.readLine(line) and line != ""):
      let (ok, name, val) = line.scanTuple("$+:$s$i")
      if ok and name.cmpIgnoreCase("Content-Length") == 0:
        contentLength = val
        break
    # Read the empty line
    discard stdin.readLine()
    # Now read the body
    var body = newString(contentLength)
    assert stdin.readChars(body) == contentLength, "Only partial body was sent"

    return body.parseJson()
  except CatchableError as e:
    raise (ref ServerError)(code: InvalidRequest, msg: e.msg)


var stdoutLock: Lock
  ## Lock on stdout. Allows responding to messages to be threadsafe
initLock(stdoutLock)


proc readRequest*(): Message =
  ## Returns either a [RequestMessage] or [NotificationMessage]
  const options = JOptions(allowMissingKeys: true)
  let data = readPayload()
  try:
    if "id" in data: # Notifications dont have an ID
      if "method" in data:
        return data.jsonTo(RequestMessage, options)
      else:
        return data.jsonTo(ResponseMessage, options)
    else:
      return data.jsonTo(NotificationMessage, options)
  except CatchableError as e:
    raise (ref ServerError)(code: ParseError, msg: e.msg)


proc writeHeader(f: File, name: string, val: string) =
  ## Writes a header to the file
  f.write(&"{name}: {val}\r\n")

proc id*(m: Message): JsonNode =
  ## Tries to get the ID of a message
  case m:
  of RequestMessage:
    m.id.get(newJNull())
  of ResponseMessage:
    m.id
  else:
    newJNull()

proc writeResponse(respBody: string) =
  ## Writes the result to stdout and flushes so client can read it
  # I think I remember seeing Nim has a stdout lock? But have this anyways
  # just to be safe
  withLock stdoutLock:
    stdout.writeHeader("Content-Length", $respBody.len)
    stdout.write("\r\n")
    stdout.write(respBody)
    stdout.flushFile()

proc sendPayload[T](payload: sink T) {.gcsafe.} =
  {.gcsafe.}:
    let resp = payload.toJson()

  let respBody = $resp
  respBody.writeResponse()


proc respond*(request: Message, err: ServerError) =
  ## Responds to a request with an error
  let payload = ResponseError(
    code: err.code,
    message: err.msg,
    data: option(err.data)
  )
  sendPayload(ResponseMessage(id: request.id, error: some payload))

proc respond*(request: Message, payload: JsonNode) =
  ## Responds to a request with a result
  sendPayload(ResponseMessage(id: request.id, `result`: some payload))

proc send*[T: Message](msg: sink T) =
  ## Sends a message to the client
  # TODO: Some kind of ID generation to match up responses
  sendPayload(msg)

proc sendNotification*(meth: static[string], payload: getMethodParam(meth)) {.gcsafe.} =
  static:
    assert meth.isNotification(), meth & " is not a notification"
  {.gcsafe.}:
    send(
      NotificationMessage(
        `method`: meth,
        params: some payload.toJson()
      )
    )
proc sendRequestMessage*(meth: static[string], payload: getMethodParam(meth)): string {.gcsafe.} =
  static:
    assert not meth.isNotification(), meth & " is not a request"
  result = $genNanoID()
  {.gcsafe.}:
    send(
      RequestMessage(
        `method`: meth,
        params: payload.toJson(),
        id: some toJson(result)
      )
    )



proc showMessage*(message: string, typ: MessageType) =
  ## Sends a message to be shown in the client
  sendNotification(windowShowMessage, ShowMessageParams(`type`: typ, message: message))


