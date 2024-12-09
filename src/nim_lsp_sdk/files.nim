## Implements an abstraction layer for accessing files

# TODO: Use streams instead so that we can support None sync by passing direct file stream

import pkg/minilru

import ./[errors, types, customast]

import std/[strformat, options, logging]

import "$nim"/compiler/ast

const NoVersion* = -1

type
  StoredFile* = ref object
    version* = NoVersion
      ## Version specified by the client
    content*: string
      ## File content. This is stored in memory for simplicity sake
    ast*: ParsedFile
      ## AST of the content.
    errors*: seq[ParsedError]
      ## Errors for the current content

  Files* = LruCache[DocumentURI, StoredFile]
    ## Mapping of path to files.
    ## Since extra context will (eventually) be stored here we use an LRU
    ## cache so the memory doesn't blow out

  FileNotInCache* = object of IOError
    ## Raised when a file tries to get accessed but
    ## its not in the cache

  InvalidFileVersion* = object of IOError
    ## Raised when an operation on a certain version of
    ## a file is done but that version isn't the one in
    ## the cache

func initFiles*(size: int): Files =
  ## Constructs the files. Small wrapper since I'll add more logic later
  Files.init(size)

func rawGet*(x: var Files, path: DocumentURI, version = NoVersion): StoredFile =
  let res = x.get(path)
  # Convert result into an exception
  if res.isNone():
    raise (ref FileNotInCache)(msg: fmt"'{path}' is not in the cache")
  let file = res.unsafeGet()
  # Version check
  if version != NoVersion and file.version notin [version, NoVersion]:
    raise (ref InvalidFileVersion)(msg: "'{path}' version has invalid version")
  return file

func `[]`*(
  x: var Files,
  path: DocumentURI,
  version = NoVersion
): string {.raises: [FileNotInCache, InvalidFileVersion].} =
  ## Returns a file and checks its version is correct.
  ## If [NoVersion] is passed for [version] then it doesn't check the versions
  return x.rawGet(path, version).content

proc parseFile*(x: var Files, path: DocumentURI, version = NoVersion): ParsedFile =
  ## Parses the file, and returns it. Returns cached AST if file hasn't
  ## changed
  let data = x.rawGet(path, version)
  if data.ast.ast.isNil:
    data.ast = path.parseFile(data.content)
  return data.ast

proc put*(x: var Files, path: DocumentURI, data: string, version: int) =
  ## Adds a file into the file cache
  debug(fmt"Adding {path}")
  x.put(path, StoredFile(version: version, content: data))

# proc set*(x: var Files, path: string, errors: sink seq[ParsedError]) =
#   x.rawGet(path)

proc put*(x: var Files, path: DocumentURI, data: string) =
  x.put(path, data, NoVersion)
