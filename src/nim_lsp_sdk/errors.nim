import types
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
    # TODO: case statement missing cases, deprecated/unused


  ParsedError* = object
    ## Error message put into a structure that I can more easily display
    ## Wish the compiler had a structured errors mode
    name*: string
      ## The name given in the first line
    range*: Range
      ## Start/end position that the error corresponds to
    severity*: DiagnosticSeverity
    file*: string
    case kind*: ErrorKind
    of Any:
      fullText*: string
    # of TypeMisMatch:
      # args: seq[string]
        ## The args that its getting called with
    of Unknown, AmbigiousIdentifier:
      possibleSymbols*: seq[string]

