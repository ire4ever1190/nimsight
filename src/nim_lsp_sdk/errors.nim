import std/[pegs, sequtils, strutils, sugar, strformat, options]

import types, customast

import utils/[ast, stringMatch]

import std/[macros, strscans]

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

  NimLocation = object
    ## Location, but lines are in Nim format (1 indexed for lines/columns)
    file*: string
    line*, col*: uint

  RelatedInfo* = object
    ## Other messages that are related to an error.
    ## Things like template instanitations
    location*: NimLocation
    msg*: string

  ParsedError* = object
    ## Nim error that is parsed into a structured format
    msg*: string
      ## Full raw message from Nim
    severity*: DiagnosticSeverity
    location*: NimLocation
    relatedInfo*: seq[RelatedInfo]
      ## Other positions that are relevant to this error
    case kind*: ErrorKind
    of Any, RemovableModule: discard
    of Unknown, AmbigiousIdentifier:
      possibleSymbols*: seq[string]

const unitSep* = '\31'
  ## Separator Nim compiler uses to split error messages

func `$`*(e: ParsedError): string =
  result &= e.msg & "\n"
  case e.kind
  of Unknown, AmbigiousIdentifier:
    if e.possibleSymbols.len > 0:
      result &= "Did you mean?\n"
      for possible in e.possibleSymbols:
        result &= &"- {possible}\n"
      result.setLen(result.len - 1)
  else: discard
  result.strip()

let grammar = peg"""
msgLine <- {path} position ' ' ((&errorLevel {errorLevel} ': ' {@}($ / internalName)) / {instantiation} \n)
instantiation <-
  ('template/generic instantiation of `' @ '` from here') /
  'template/generic instantiation from here'

# The name that the compiler uses internally
internalName <- '[' @ ']'
errorLevel <- 'Hint' / 'Warning' / 'Error'
position <- '(' {\d+} ', ' {\d+} ')'
# Match until we reach the (line, col)
path <- (!position .)*
"""

iterator msgChunks*(msg: string): string =
  ## Returns each msg chunk from Nim output.
  for msg in msg.split(unitSep):
    if not msg.isEmptyOrWhitespace():
      yield msg

proc splitMsgLines(msg: string): seq[string] =
  ## Splits a full error message into a series of lines
  {.cast(gcsafe).}:
    for part in msg.findAll(grammar):
      result &= part

proc findNode*(ast: Tree, loc: NimLocation): Option[NodeIdx] =
  ## Finds the node that points to a location
  return ast[].findNode(loc.line, loc.col - 1)

proc toRange*(ast: Tree, loc: NimLocation): Option[Range] =
  ## Converts a `NimLocation` into an LSP `Range`.
  let node = ast.findNode(loc)
  if node.isSome():
    return some ast.getPtr(node.unsafeGet()).initRange()

proc toLocation*(ast: Tree, loc: NimLocation): Option[Location] =
  ## Converts a [NimLocation] into an LSP [Location]
  let range = ast.toRange(loc)
  if range.isSome:
    return some Location(
        uri: initDocumentURI(loc.file),
        range: range.unsafeGet()
    )

func toDiagnosticSeverity(x: sink string): DiagnosticSeverity =
  ## Returns the diagnostic severity for a string e.g. Hint, Warning
  case x
  of "Hint": DiagnosticSeverity.Hint
  of "Warning": DiagnosticSeverity.Warning
  of "Error": DiagnosticSeverity.Error
  else:
    # Spec mentions to interpret as Error if missing
    DiagnosticSeverity.Error

proc parseError*(msg: string): ParsedError =
  ## Given a full error message, it returns a parsed error.
  ## "full errror message" meaning it handles a full block separated by UnitSep (See --unitsep in Nim).
  # Parse out information from the error message.
  # All 'generic/template instantiation' messages come before the actual message
  let
    lines = splitMsgLines(msg)
    error = lines[^1]
    instantiations = lines[0 ..< ^1]

  # Now parse actual info from the messages
  var matches = default(array[5, string])
  doAssert error.match(grammar, matches)
  let
    file = matches[0]
    line = matches[1].parseUInt()
    col = matches[2].parseUInt()
    lvl = matches[3].toDiagnosticSeverity()
    msg = matches[4]

  result = ParsedError(
    location: NimLocation(
      file: file,
      line: line,
      col: col
    ),
    msg: msg,
    severity: lvl,
    kind: Any
  )

  # Add the instanitations as related information
  for inst in instantiations:
    var matches = default(array[5, string])
    doAssert inst.match(grammar, matches)
    result.relatedInfo &= RelatedInfo(
      msg: matches[3],
      location: NimLocation(
        file: matches[0],
        line: matches[1].parseUInt(),
        col: matches[2].parseUint()
      )
    )

  # Try and match the message against some patterns
  case match(msg):
  of "undeclared identifier: '$w'$scandidates (edit distance, scope distance); see '--spellSuggest':$s$*" as (ident, rest):
    # Parse out the different options
    let options = collect:
      for line in rest.splitLines():
        let (ok, _, _, ident) = line.scanTuple("($i, $i): '$+'$.")
        if ok:
          ident

    # Make the error more concise
    result.msg = fmt"Undeclared identifier: '{ident}'"

    # Assign the options
    {.cast(uncheckedAssign).}:
      result.kind = Unknown
      result.possibleSymbols = options
