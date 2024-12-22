import std/[pegs, sequtils, strutils, sugar, strformat]

import types, customast

import utils/ast

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

  RelatedInfo = object
    ## Other messages that are related to an error.
    ## Things like template instanitations
    location: NimLocation
    msg: string

  ParsedError* = object
    ## Nim error that is parsed into a structured format
    msg*: string
      ## The name given in the first line
    severity*: DiagnosticSeverity
    location*: NimLocation
    relatedInfo*: seq[RelatedInfo]
      ## Other positions that are relevant to this error
    case kind*: ErrorKind
    of Any, RemovableModule:
      fullText*: string
    # of TypeMisMatch:
      # args: seq[string]
        ## The args that its getting called with
    of Unknown, AmbigiousIdentifier:
      possibleSymbols*: seq[string]

const unitSep* = '\31'
  ## Separator Nim compiler uses to split error messages

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

iterator msgChunks(msg: string): string =
  ## Returns each msg chunk from Nim output.
  for msg in msg.split(unitSep):
    if not msg.isEmptyOrWhitespace():
      yield msg

proc splitMsgLines(msg: string): seq[string] =
  ## Splits a full error message into a series of lines
  {.cast(gcsafe).}:
    for part in msg.findAll(grammar):
      result &= part

type Match = object
proc match(x: string): Match = Match()

macro matches(inp, pat: string, variables: untyped): bool =
  ## Support for strscans in match statement
  # Add call
  let call = newCall(bindSym"scanTuple", inp, pat)

  # Now create the tuple that the call gets unpacked into
  let
    okSym = nskLet.genSym("ok")
    vars = nnkVarTuple.newTree(okSym)
  for variable in variables:
    vars &= variable
  vars &= newEmptyNode()
  vars &= call

  result = newStmtList(nnkLetSection.newTree(vars), okSym)
  echo result.toStrLit()

macro `case`(match: Match): untyped =
  ## Macro for nicely matching a string against a series of patterns.
  # Input is the string to match against
  let inp = match[0][1]

  # Go through each branch.
  # Generate a call to `matches` which checks if the input
  # matches the pattern and returns a bool along with variables in
  # scope if it does
  result = newStmtList()
  for branch in match[1 .. ^1]:
    echo branch.treeRepr
    let
      body = branch[1]
      vars = branch[0][2]
      pat = branch[0][1]
    let check = nnkCall.newTree(bindSym"matches", inp, pat, vars)
    result &= newBlockStmt(
      newEmptyNode(),
      newIfStmt((check, body))
    )
  echo result.toStrLit

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
    msg: error,
    severity: lvl,
    kind: Any,
    fullText: error
  )

  # Add the instanitations as related information
  for inst in instantiations:
    var matches = default(array[5, string])
    doAssert inst.match(grammar, matches)
    result.relatedInfo &= RelatedInfo(
      msg: matches[^1],
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
