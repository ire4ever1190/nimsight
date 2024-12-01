## Implements an abstraction layer for accessing files

# TODO: Use streams instead so that we can support None sync by passing direct file stream

import pkg/minilru

import std/[strformat, options]

const NoVersion* = -1

type
  File = object
    version* = NoVersion
      ## Version specified by the client
    content*: string
      ## File content. This is stored in memory for simplicity sake
  Files* = LruCache[string, File]
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

func `[]`*(x: var Files, path: string, version = NoVersion): string {.raises: [FileNotInCache, InvalidFileVersion].} =
  ## Returns a file and checks its version is correct.
  ## If [NoVersion] is passed for [version] then it doesn't check the versions
  let res = x.get(path)
  # Convert result into an exception
  if res.isNone():
    raise (ref FileNotInCache)(msg: fmt"'{path}' is not in the cache")
  let file = res.unsafeGet()
  # Version check
  if version != NoVersion and file.version notin [version, NoVersion]:
    raise (ref InvalidFileVersion)(msg: "'{path}' version has invalid version")

func put*(x: var Files, path, data: string, version: int) =
  ## Adds a file into the file cache
  x.put(path, File(version: version, content: data))

func put*(x: var Files, path, data: string) =
  x.put(path, data, NoVersion)
