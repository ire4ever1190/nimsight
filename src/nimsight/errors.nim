import "$nim"/compiler/[ast, parser, syntaxes]

import std/[strutils, sugar, strformat, options, paths, sequtils, logging]

import customast

import sdk/types

import utils/[stringMatch]

import std/strscans
import pkg/nort

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
    TypeMismatch
      ## Function exists, but arguments don't line up
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

  Mismatch* = object
    idx*: int ## Index of parameter that has the mismatch
    expected*: string ## What parameter was expected in this position

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
    of TypeMismatch:
      passed*: seq[string]
        ## Types that were passed to the call
      mismatches*: seq[Mismatch]
        ## Different mismatches for possible overloads

  ReportLevel = enum
    Hint
    Info
    Warning
    Error

const unitSep* = '\31'
  ## Separator Nim compiler uses to split error messages

func badParameter*(e: ParsedError): Option[tuple[msg: string, idx: int]] =
  ## Returns the message and parameter that is bad for a mismatch.
  ## Sometimes the user is completely wrong, in which case we don't try and find the one bad parameter
  ## `err` must be a TypeMismatch
  if e.mismatches.len == 1:
    # Single mismatch, return what we expected
    let badParam = e.mismatches[0].idx - 1
    some (fmt"Expected `{e.mismatches[0].expected}` but got `{e.passed[badParam]}`", badParam)
  elif e.mismatches.len > 1 and allIt(e.mismatches, it.idx == e.mismatches[0].idx):
    # If the mismatches all happen in the same position, return the possible types
    let badParam = e.mismatches[0].idx - 1
    let possible = collect:
      for mismatch in e.mismatches:
        fmt"`{mismatch.expected}`"
    let allOptions = possible.join(", ")
    some (fmt"Expected one of {allOptions} but got `{e.passed[badParam]}`", badParam)
  else: none((string, int))

func `$`*(e: ParsedError): string =
  result &= e.msg & "\n"
  case e.kind
  of Unknown, AmbigiousIdentifier:
    if e.possibleSymbols.len > 0:
      result &= "Did you mean?\n"
      for possible in e.possibleSymbols:
        result &= &"- {possible}\n"
      result.setLen(result.len - 1)
  of TypeMismatch:
    let info = e.badParameter
    if info.isSome():
      return info.get()[0]
  else: discard
  result.strip()

# Basics we share
let
  nl: Combinator[Void] = -e'\n'
  ws: Combinator[Void] = - *(-e(Whitespace))

let mismatchGrammar = block:
  let
    header = -e"Expression: " * -dot().untilIncl(nl)
    expectedHeader = e"Expected one of (first mismatch at [position]):"
    idx = between(digit()$position, e'[', e']')
    mismatch = idx * ws * dot().until(nl)$decl
    passedType: Combinator[string] = ws * -idx * -dot().untilIncl(e": ") * dot().untilIncl(nl)

  -dot().untilIncl(header) * (*passedType)$passedTypes * -dot().untilIncl(expectedHeader) * *(nl * mismatch)$mismatches

let errGrammar = block:
  let
    stacktraceHeader = e "stack trace: (most recent call last)\n"
    position = e('(') * digit()$line * e", " * digit()$column * e')'
    path = *(-(not (position | nl)) * dot())
    errorLevel = expect(ReportLevel)
    # Code name of the error/warning the compiler has internally e.g. [UndeclaredIdentifier].
    # This always appears at the end
    internalName = dot().until(e']').between(e'[', e']') * fin()
    instantiation = dot().until(nl)
    errorMsg = dot().until(internalName)$msg * ws * ?internalName$name
    errorLine = errorLevel$level * e": " * errorMsg
    msgLine = path$file * position * -(e' ') * any((error: errorLine, instantiation: instantiation * -nl))$info
  # We need to track if the first line indicates its a stacktrace, this lets us
  # catch if its a static exception
  (?stacktraceHeader).map(it => it.isSome())$isException * ws * msgLine

iterator msgChunks*(msg: string): string =
  ## Returns each msg chunk from Nim output.
  for msg in msg.split(unitSep):
    if not msg.isEmptyOrWhitespace():
      yield msg

proc findNode*(ast: Tree, loc: NimLocation): Option[NodeIdx] =
  ## Finds the node that points to a location
  return ast[].findNode(loc.line, loc.col - 1)

proc toRange*(ast: Tree, loc: NimLocation): Option[Range] =
  ## Converts a `NimLocation` into an LSP `Range`.
  let node = ast.findNode(loc)
  if node.isSome():
    return some ast.getPtr(node.unsafeGet()).initRange()

proc findRange*(ast: Tree, err: ParsedError): Option[Range] =
  ## Finds the range that corresponds to an error
  let idx = ast.findNode(err.location)
  if idx.isNone(): return none(Range)
  let node = ast.getPtr(idx.get())

  case err.kind
  of TypeMismatch:
    # We need to find that parameter in the node
    let info = err.badParameter
    if info.isSome():
      # Get the n'th param (+1 to skip call ident)
      return some node[info.get().idx + 1].initRange()
  else:
    return some node.initRange()

proc toLocation*(ast: Tree, loc: NimLocation): Option[Location] =
  ## Converts a [NimLocation] into an LSP [Location]
  let range = ast.toRange(loc)
  if range.isSome:
    return some Location(
        uri: initDocumentURI(loc.file),
        range: range.unsafeGet()
    )

func toDiagnosticSeverity(x: ReportLevel): DiagnosticSeverity =
  ## Returns the diagnostic severity for a string e.g. Hint, Warning
  case x
  of Hint, Info: DiagnosticSeverity.Hint
  of Warning: DiagnosticSeverity.Warning
  of Error: DiagnosticSeverity.Error
  else:
    # Spec mentions to interpret as Error if missing
    DiagnosticSeverity.Error

proc readError*(info: errGrammar.T): ParsedError {.gcsafe.} =

  # Parse values from the matches
  let
    file = info.file.strip()
    line = info.line
    col = info.column
    lvl = info.info.error.level
    msg = info.info.error.msg

  # Construct a basic ParsedError
  result = ParsedError(
    location: NimLocation(
      file: Path(file),
      line: line.uint,
      col: col.uint
    ),
    msg: msg,
    severity: lvl.toDiagnosticSeverity(),
    kind: Any
  )

proc initMismatch(idx: int, procHeader: string): Mismatch =
  ## Creates a mismatch from an error like `[$idx] proc foo(a, b: bool)`
  ## This parses the proc header to figure out what the expected type is
  let (_, root, errors) = nimParseFile("stdin", procHeader)
  assert errors.len == 0, fmt"Got errors when parsing mismatch: {errors}"
  let params = root[0][3] # nkStmtList -> nkProcDef

  # Step through the params until we reach the mismatch
  var currIdx = 1
  for i in 1 ..< params.len:
    let identDef = params[i]
    for j in 0 ..< identDef.len - 2:
      if currIdx == idx:
        # Return the type for this param
        return Mismatch(idx: idx, expected: identDef[^2].ident.s)
      currIdx += 1

  raise (ref ValueError)(msg: fmt"Failed to find parameter at {idx} for {procHeader}")

proc parseError*(msg: string): ParsedError =
  ## Given a full error message, it returns a parsed error.
  ## "full error message" meaning it handles a full block separated by UnitSep (See --unitsep in Nim).

  # Parse out information from the error message.
  # All 'generic/template instantiation' messages come before the actual message
  let lines = collect:
    for match in errGrammar.match(msg):
      match

  # Usually happens when the compiler segfaults.
  # Best to raise an error instead of letting the whole server crash
  if lines.len == 0:
    raise (ref ValueError)(msg: fmt"Failed to parse logs from: {msg}")

  let
    error = lines[^1]
    instantiations = lines[0 ..< ^1]

  result = readError(error)

  # Add the instanitations as related information
  for inst in instantiations:
    # If an exception is raised at compile time, first line has this
    if inst.isException:
      {.cast(uncheckedAssign).}:
        result.kind = Exception
      continue

    result.relatedInfo &= RelatedInfo(
      msg: inst.info.instantiation,
      location: NimLocation(
        file: Path(inst.file),
        line: inst.line.uint,
        col: inst.column.uint
      )
    )

  if result.kind == Exception:
    echo error
    result.exp = error.info.error.name.get()

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
      let err = errGrammar.match(line.strip(chars = {'>'} + Whitespace)).get().readError()
      result.relatedInfo &= RelatedInfo(
        msg: err.msg,
        location: err.location
      )

  let mismatch = mismatchGrammar.match(result.msg)
  if mismatch.isSome:
    {.cast(uncheckedAssign).}:
      result.kind = TypeMismatch
    result.passed = mismatch.get().passedTypes
    result.mismatches = collect:
      for mismatch in mismatch.get().mismatches:
        initMismatch(mismatch.position, mismatch.decl)
