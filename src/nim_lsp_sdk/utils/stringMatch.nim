## Small utility for matching a string against a series of patterns.
## Can bind to the captured substrings

import std/[macros, strscans]

type Match = object
proc match*(x: string): Match = Match()

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

macro `case`*(match: Match): untyped =
  ## Macro for nicely matching a string against a series of patterns.
  # Input is the string to match against
  let inp = match[0][1]

  # Go through each branch.
  # Generate a call to `matches` which checks if the input
  # matches the pattern and returns a bool along with variables in
  # scope if it does
  result = newStmtList()
  for branch in match[1 .. ^1]:
    let
      body = branch[1]
      vars = branch[0][2]
      pat = branch[0][1]
    let check = nnkCall.newTree(bindSym"matches", inp, pat, vars)
    result &= newBlockStmt(
      newEmptyNode(),
      newIfStmt((check, body))
    )
