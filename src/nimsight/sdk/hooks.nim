## JSON hooks for parsing special structures

{.used.}

import std/[json, jsonutils, options, strtabs, tables]
import std/macros
import types
import utils/union

#
# From JSON
#

proc fromJsonHook*(ev: var TextDocumentContentChangeEvent, json: JsonNode, options: JOptions) =
  if "range" in json:
    ev = TextDocumentContentChangeEvent(incremental: true, range: json["range"].jsonTo(Range, options), text: json["text"].getStr())
  else:
    ev = TextDocumentContentChangeEvent(incremental: false, text: json["text"].getStr())

#
# To JSON
#

proc toJsonHandleOptions*(val: JsonNode, opt = initToJsonOptions()): JsonNode {.gcsafe.} =
  return val

proc toJsonHandleOptions*[T](val: openArray[T], opt = initToJsonOptions()): JsonNode {.gcsafe.} =
  result = newJArray()
  for item in val:
    result &= item.toJsonHandleOptions(opt)

proc toJsonHandleOptions*[T](val: T, opt = initToJsonOptions()): JsonNode {.gcsafe.} =
  {.gcsafe.}:
    val.toJson(opt)

proc toJsonHandleOptions*[T: object | ref object](val: T, opt = initToJsonOptions()): JsonNode {.gcsafe.} =
  mixin toJsonHandleOptions
  result = newJObject()
  when T is ref:
    if val.isNil():
      return newJNull()
  for field, value in (when T is ref: val[] else: val).fieldPairs:
    # Options won't appear full stop
    when typeof(value) is Option:
      if value.isSome():
        result[field] = value.unsafeGet().toJsonHandleOptions(opt)
    else:
      result[field] = value.toJsonHandleOptions(opt)

proc toJsonHook*(c: ErrorCode, options: ToJsonOptions): JsonNode =
  return newJInt(c.ord)

proc toJsonHook*[V](t: Table[DocumentURI, V], opt = initToJsonOptions()): JsonNode =
  result = newJObject()
  for k, v in pairs(t):
    # not sure if $k has overhead for string
    result[$k] = toJsonHandleOptions(v, opt)

proc toJsonHook*(r: ResponseMessage, options: ToJsonOptions): JsonNode =
  result = %* {
    "jsonrpc": "2.0",
  }
  if r.id.kind != JNull:
    result["id"] = r.id
  assert r.`result`.isSome() xor r.error.isSome(), "Either result or error must be set in ResponseMessage"
  if r.`result`.isSome():
    result["result"] = r.`result`.unsafeGet().toJsonHandleOptions(options)
  else:
    result["error"] = r.error.unsafeGet().toJson(options)
    stderr.write(result["error"].pretty())
