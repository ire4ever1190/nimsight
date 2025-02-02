## Contains utilities for working with stored Nim files

import sdk/[files, types, server]
import sdk/utils/locks
import errors, customast

type
  NimStoredFile* = ref object of BasicFile
    ast*: ParsedFile
      ## AST of the content.
    errors*: seq[ParsedError]
      ## Errors for the current content
    ranCheck*: bool
      ## Whether `nim check` has been ran on the file. If it hasn't then
      ## the errors stored are just parser errors

proc parseFile*(x: var FileStore, path: DocumentURI, version = NoVersion): ParsedFile =
  ## Parses the file, and returns it. Returns cached AST if file hasn't
  ## changed
  let data = NimStoredFile(x.rawGet(path, version))
  if data.ast.ast.isNil:
    data.ast = path.parseFile(data.content)
  return data.ast

proc parseFile*(h: RequestHandle, uri: DocumentURI, version = NoVersion): ParsedFile =
  ## Helper to get a file from the server
  h.server[].files.write().value.parseFile(uri, version)
