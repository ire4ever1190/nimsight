import types, customast

import utils/ast

import "$nim"/compiler/ast

type
  ErrorKind* = enum
    Any
      ## Fallback for when we cant parse the error.
      ## We just display the full message for this
      ## TypeMisMatch
      ## Type mismatch when calling a proc
    Unknown
      ## Unknown symbol
    AmbigiousIdentifier
      ## Trying to use an identifer when it could come from multiple modules
    RemovableModule
      ## Either the import is unused or duplicated
    # TODO: case statement missing cases, deprecated/unused


  ParsedError* = object
    ## Error message put into a structure that I can more easily display
    ## Wish the compiler had a structured errors mode
    name*: string
      ## The name given in the first line
    node*: NodePtr
    severity*: DiagnosticSeverity
    file*: string
    case kind*: ErrorKind
    of Any, RemovableModule:
      fullText*: string
    # of TypeMisMatch:
      # args: seq[string]
        ## The args that its getting called with
    of Unknown, AmbigiousIdentifier:
      possibleSymbols*: seq[string]

func range*(e: ParsedError): Range {.gcsafe.} =
  ## Start/end position that the error corresponds to
  e.node.initRange()
