## Contains utilities for working with stored Nim files

import sdk/types
import errors, customast

## Implements an abstraction layer for accessing files

# TODO: Use streams instead so that we can support None sync by passing direct file stream. (Past me what the fuck is this comment)

import pkg/minilru
export minilru

import std/[strformat, options]


const NoVersion* = -1
  ## Sential value for not caring about the version

type
  FileError* = object
    ## Error that belongs to a file
  NimFile* = ref object
    ## File stored inside the server
    content*: string
      ## Contents of the file
    version* = NoVersion
      ## The version has specified by the client
      ## Stores extra information about a Nim file
    ast*: ParsedFile
      ## AST of the content.
    errors*, syntaxErrors: seq[ParsedError]
      ## Errors for the current content.
      ## Syntax errors are kept separate so we can update them quicker
    ranCheck*: bool
      ## Whether `nim check` has been ran on the file. If it hasn't then
      ## the errors stored are just parser errors

  FileStore* = LruCache[DocumentURI, NimFile]
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

func rawGet*(x: var FileStore, path: DocumentURI, version = NoVersion): NimFile =
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

# proc put*(x: var FileStore, path: DocumentURI, file: sink NimFile) =
#   ## Adds a file into the file cache
#   x.put(path, file)

proc put*(x: var FileStore, path: DocumentURI, content: string, version = NoVersion) =
  x.put(path, NimFile(content: content, version: version))


proc parseFile*(x: var FileStore, path: DocumentURI, version = NoVersion): ParsedFile =
  ## Parses the file, and returns it. Returns cached AST if file hasn't
  ## changed
  var data = x.rawGet(path, version)
  if data.ast.ast.isNil:
    data.ast = parseFile(path, data.content)
  return data.ast

export minilru
