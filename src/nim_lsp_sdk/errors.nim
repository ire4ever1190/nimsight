import std/[pegs, sequtils]

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

  ErrorPart = object
    ## Parsed version of an error message.
    ## Bit easier to handle compared to a raw string for parsing
    name: string
    severity: DiagnosticSeverity
    file: string
    line, col: uint
    instantiations: seq[ErrorPart]
      ## All the instantiation messages that come before it

func range*(e: ParsedError): Range {.gcsafe.} =
  ## Start/end position that the error corresponds to
  e.node.initRange()

let grammar = peg"""
msgLine <- {path} position ' ' ((&errorLevel {errorLevel} ': ' {@}internalName) / instantiation) \n
instantiation <- 'template/generic instantiation of `' {@} '` from here'
# The name that the compiler uses internally
internalName <- '[' @ ']'
errorLevel <- 'Hint' / 'Warning' / 'Error'
position <- '(' {\d+} ', ' {\d+} ')'
# Match until we reach the (line, col)
path <- (!position .)*
"""

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

macro `case`(match: Match): untyped =
  ## Macro for nicely matching a string against a series of patterns.
  echo match.treeRepr
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

proc parseError*(msg: string, node: NodePtr): ParsedError =
  ## Given a full error message, it returns a parsed error.
  ## "full errror message" meaning it handles a full block separated by UnitSep (See --unitsep in Nim).
  let
    lines = splitMsgLines(msg)
    error = lines[^1]
    instantiations = lines[0 ..< ^1]
  var matches = newSeq[string](5)
  doAssert error.match(grammar, matches)

  let msg = matches[4]
  case match(msg):
  of "'$w' is declared but not used" as (ident):
    discard
  of "undeclared identifier: '$w'" as (ident):
    echo rest
    discard
