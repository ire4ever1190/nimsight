import std/[pegs, strutils, sugar, strformat, options, paths]

import customast

import sdk/types

import utils/[stringMatch]

import std/strscans

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
    Exception
      ## Exception was raised at compile time
    # TODO: case statement missing cases, deprecated/unused

  NimLocation = object
    ## Location, but lines are in Nim format (1 indexed for lines/columns)
    file*: Path
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
    of Exception:
      exp*: string

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
S <- msgLine / stacktraceHeader
msgLine <- {path} position ' ' ((&errorLevel {errorLevel} ': ' {@}($ / internalName)) / {instantiation} \n)

# Any line that leads up an an error, this gives us info about where it originated from in user code
instantiation <- (!\n .)*

# Code name of the error/warning the compiler has internally e.g. [UndeclaredIdentifier]
internalName <- '[' {@} ']' $
errorLevel <- 'Hint' / 'Warning' / 'Error'
position <- '(' {\d+} ', ' {\d+} ')'
# Match until we reach the (line, col)
path <- (!(position / \s) \S)*


stacktraceHeader <- 'stack trace: (most recent call last)' \n
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

proc matchGrammar(msg: string): array[6, string] =
  {.gcsafe.}:
    assert msg.match(grammar, result), "Grammar doesn't match: " & msg

proc readError*(msg: string): ParsedError {.gcsafe.} =
  ## Parses an error line into a basic structure.
  ## Doesn't fully parse the message
  let matches = msg.matchGrammar()

  # Parse values from the matches
  let
    file = matches[0].strip() # Lines after first error start with newline, easier to fix here
    line = matches[1].parseUInt()
    col = matches[2].parseUInt()
    lvl = matches[3].toDiagnosticSeverity()
    msg = matches[4]

  # Construct a basic ParsedError
  result = ParsedError(
    location: NimLocation(
      file: Path(file),
      line: line,
      col: col
    ),
    msg: msg,
    severity: lvl,
    kind: Any
  )

proc parseError*(msg: string): ParsedError =
  ## Given a full error message, it returns a parsed error.
  ## "full errror message" meaning it handles a full block separated by UnitSep (See --unitsep in Nim).

  # Parse out information from the error message.
  # All 'generic/template instantiation' messages come before the actual message
  let lines = splitMsgLines(msg)

  # Usually happens when the compiler segfaults.
  # Best to raise an error instead of letting the whole server crash
  if lines.len == 0:
    raise (ref ValueError)(msg: "Failed to parse logs from: " & msg)

  let
    error = lines[^1]
    instantiations = lines[0 ..< ^1]

  result = readError(error)

  # Add the instanitations as related information
  for inst in instantiations:
    # If an exception is raised at compile time, first line has this
    if inst.strip() == "stack trace: (most recent call last)":
      {.cast(uncheckedAssign).}:
        result.kind = Exception
      continue

    let matches = inst.matchGrammar()

    result.relatedInfo &= RelatedInfo(
      msg: matches[3],
      location: NimLocation(
        file: Path(matches[0]),
        line: matches[1].parseUInt(),
        col: matches[2].parseUint()
      )
    )

  if result.kind == Exception:
    result.exp = error.matchGrammar()[5]

  # Try and match the message against some patterns
  case match(result.msg):
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
  of "'$w' can have side effects$s$*" as (ident, calls):
    result.msg = fmt"'{ident}' can have side effects"

    # Add the calls as related information
    for line in calls.splitLines():
      if line.isEmptyOrWhitespace(): continue
      let err = line.strip(chars = {'>'} + Whitespace).readError()
      result.relatedInfo &= RelatedInfo(
        msg: err.msg,
        location: err.location
      )
