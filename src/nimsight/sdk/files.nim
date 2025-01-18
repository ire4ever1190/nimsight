## Implements an abstraction layer for accessing files

# TODO: Use streams instead so that we can support None sync by passing direct file stream

import pkg/minilru

import std/[strformat, options]

import types

const NoVersion* = -1
  ## Sential value for not caring about the version

type
  BasicFile* = ref object of RootObj
    ## Basic file that just stores the contents.
    ## Can be inherited to add extra metadata
    content*: string
      ## Contents of the file
    version* = NoVersion
      ## The version has specified by the client

  FileStore* = LruCache[DocumentURI, BasicFile]
    ## Holds all the files stored by the server.
    ## Implemented as an LRU cache to auto handle unloading old files

  FileNotInCache* = object of IOError
    ## Raised when a file tries to get accessed but
    ## its not in the cache

  InvalidFileVersion* = object of IOError
    ## Raised when an operation on a certain version of
    ## a file is done but that version isn't the one in
    ## the cache

func initFileStore*(size: int): FileStore =
  ## Constructs the files. Small wrapper since I'll add more logic later
  FileStore.init(size)

func rawGet*(x: var FileStore, path: DocumentURI, version = NoVersion): BasicFile =
  ## This gets the internal stored object from the file store.
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
  x: var FileStore,
  path: DocumentURI,
  version = NoVersion
): string {.raises: [FileNotInCache, InvalidFileVersion].} =
  ## Returns a file and checks its version is correct.
  ## If [NoVersion] is passed for [version] then it doesn't check the versions
  return x.rawGet(path, version).content

proc put*(x: var FileStore, path: DocumentURI, data: sink string, version: int) =
  ## Adds a file into the file cache
  x.put(path, BasicFile(version: version, content: data))

proc put*(x: var FileStore, path: DocumentURI, data: sink string) =
  x.put(path, data, NoVersion)
