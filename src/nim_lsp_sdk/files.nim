## Implements an abstraction layer for accessing files

import pkg/minilru

import std/[strformat, options]

const NoVersion = -1

type
  File = object
    version = NoVersion
      ## Version specified by the client
    content: string
      ## File content. This is stored in memory for simplicity sake
  Files = LruCache[string, File]
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

func initFiles*(): Files =
  Files.init(20) # TODO: Make this configurable

func `[]`(x: Files, path: string): File =
  ## Returns a file at a path
  let res = x.get(path)
  if res.isNone():
    raise (ref FileNotInCache)(msg: fmt"'{path}' is not in the cache")
  return res.unsafeGet()

func `[]`(x: Files, path: string, version: int): File =
  ## Returns a file and checks its version is correct
  result = x[path]
  if result.version notin [version, NoVersion]:
    raise (ref InvalidFileVersion)(msg: "'{path}' version has invalid version")

func add*(x: var Files, path, data: string, version: int) =
  ## Adds a file into the file cache
  x.put(path, File(version: version, content: data))

func add*(x: var Files, path, data: string) =
  x.add(path, data, NoVersion)
