## JSON hooks for parsing special structures

{.used.}

import std/[json, jsonutils, options, strtabs, tables]
import std/macros
import types

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

proc toJsonHandleOptions*[T](val: T, opt = initToJsonOptions()): JsonNode {.gcsafe.} =
  when T is JsonNode:
    if val == nil: newJNull() else: val
  elif T is object or T is (ref object):
    result = newJObject()
    when T is ref:
      if val == nil:
        return
    for field, value in (when T is ref: val[] else: val).fieldPairs:
      when field == "documentChanges":
        static: assert typeof(value) is Option
      else:
        when typeof(value) is Option:
          if value.isSome():
            result[field] = value.unsafeGet().toJsonHandleOptions(opt)
        else:
          result[field] = value.toJsonHandleOptions(opt)
  elif T is seq or T is array:
    result = newJArray()
    for item in val:
      result &= item.toJsonHandleOptions(opt)
  else:
    {.gcsafe.}:
      when compiles(val == nil):
        result = if val == nil: newJNull() else: val.toJson(opt)
      else:
        result = val.toJson(opt)

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
