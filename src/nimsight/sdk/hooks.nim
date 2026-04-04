## JSON hooks for parsing special structures

{.used.}

import std/[json, jsonutils, options, strtabs, tables]

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

proc toJsonHook*(c: ErrorCode, options: ToJsonOptions): JsonNode =
  return newJInt(c.ord)

proc toJsonHook*[V](t: Table[DocumentURI, V], opt = initToJsonOptions()): JsonNode =
  result = newJObject()
  for k, v in pairs(t):
    # not sure if $k has overhead for string
    result[$k] = toJson(v, opt)

proc toJsonHandleOptions*[T](val: T, opt = initToJsonOptions()): JsonNode {.gcsafe.} =
  ## Converts an object to JSON. Option fields are not included in the final output JSON.
  ## Technically the types are `field?: type` and not `field: type | null` so we need to
  ## remove it if missing
  when T is JsonNode:
    val
  elif T is object or T is (ref object):
    result = newJObject()
    for field, value in (when T is ref: val[] else: val).fieldPairs:
      when typeof(value) is Option:
        if value.isSome():
          result[field] = value.unsafeGet().toJsonHandleOptions()
      else:
        result[field] = value.toJsonHandleOptions()
  elif T is seq or T is array:
    result = newJArray()
    for item in val:
      result &= item.toJsonHandleOptions()
  elif T is void:
    result = newJNull()
  else:
    {.gcsafe.}:
      result = val.toJson(opt)


proc toJsonHook*(r: ResponseMessage, options: ToJsonOptions): JsonNode =
  result = %* {
    "jsonrpc": "2.0",
  }
  if r.id.kind != JNull:
    result["id"] = r.id
  assert r.`result`.isSome() xor r.error.isSome(), "Either result or error must be set in ResponseMessage"
  if r.`result`.isSome():
    result["result"] = r.`result`.unsafeGet().toJson(options)
  else:
    result["error"] = r.error.unsafeGet().toJson(options)
    stderr.write(result["error"].pretty())
