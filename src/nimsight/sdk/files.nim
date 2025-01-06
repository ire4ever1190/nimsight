## Implements an abstraction layer for accessing files

# TODO: Use streams instead so that we can support None sync by passing direct file stream

import pkg/minilru

import std/[strformat, options]

import types

const NoVersion* = -1

type
  StoredFile* {.explain.} = concept
    ## Abstract stored file. Only requirement is that
    ## it stores the actual content. Extra metadata can be stored
    ## alongisde it
    proc content(x: Self): string

  FileStore*[M: StoredFile] = LruCache[DocumentURI, M]
    ## Holds all the files stored by the server.
    ## Implemented as an LRU cache to auto handle unloading old files

  FileNotInCache* = object of IOError
    ## Raised when a file tries to get accessed but
    ## its not in the cache

  InvalidFileVersion* = object of IOError
    ## Raised when an operation on a certain version of
    ## a file is done but that version isn't the one in
    ## the cache

func initFileStore*[M](size: int): FileStore[M] =
  ## Constructs the files. Small wrapper since I'll add more logic later
  init(FileStore[M], size)

func get*[M](x: var FileStore[M], path: DocumentURI, version = NoVersion): M =
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

func `[]`*[M](
  x: var FileStore[M],
  path: DocumentURI,
  version = NoVersion
): string {.raises: [FileNotInCache, InvalidFileVersion].} =
  ## Returns a file and checks its version is correct.
  ## If [NoVersion] is passed for [version] then it doesn't check the versions
  return x.rawGet(path, version).content

proc put*[M](x: var FileStore[M], path: DocumentURI, data: sink string, version: int) =
  ## Adds a file into the file cache
  x.put(path, StoredFile[M](version: version, content: data))

proc put*[M](x: var FileStore[M], path: DocumentURI, data: sink string) =
  x.put(path, data, NoVersion)
