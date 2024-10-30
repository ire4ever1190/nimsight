import std/[osproc, streams, os, unittest, macros, strutils]


proc readBlock(x: NimNode): string =
  ## Returns the block of code that corresponds to
  ## a NimNode. Only works on code thats in a source
  ## file (i.e. not macro generated code)
  let
    info = x.lineInfoObj
    lines = info.filename.readFile().splitLines()
    start = info.line - 1
  # Find the line that the code ends on e.g. the indention levels go back up
  let indention = lines[start].indentation
  for i in start ..< lines.len:
    # When the indention changes, its a different block
    let
      line = lines[i]
      currIndent = line.strip(leading=false).indentation
    if currIndent notin [0, indention]: break
    result &= line & '\n'
  # Strip the ending, and make sure the indention is correct
  result = result.strip().unindent(indention)

proc runTest(inputFile: string): string =
  ## Runs a neovim test
  # Start the neovim process
  let configFile = currentSourcePath.parentDir() / "config.lua"
  let p = startProcess(
    "nvim", args=["nvim", "--clean", "--headless", "-u", $configFile, inputFile],
    options={poUsePath, poStdErrToStdOut}
  )
  defer: p.close()
  # Wait for it to exit, then read the output
  let
    exitCode = p.waitForExit(10000)
    output = p.outputStream().readAll()
  checkpoint output
  assert exitCode == QuitSuccess
  result = output

proc parseCommands(x: string): seq[string] =
  ## Parses all vim commands stored in the source
  ## Commands can be stored inline by prefixing with `#>` e.g.
  ## ```
  ## #> :q
  ## ```
  for line in x.splitLines:
    if line.startsWith("#> "):
      result &= line.replace("#> ", "")

macro nvimTest(body: untyped): string =
  ## Writes the body to a temp file and then
  ## runs nvim on it. Returns the messages as a string
  # Write the code to a temp file to be read by the test
  let code = body.readBlock()
  # TODO: Better temp file naming
  let tempBaseName = "/tmp/" & $body.lineInfoObj.line
  let file = tempBaseName & ".nim"
  file.writeFile(code)
  # Extract the commands from the source
  (tempBaseName & ".vim").writeFile(code.parseCommands().join("\n"))

  result = quote do:
    runTest(`file`)


test "No errors on startup":
  let output = nvimTest:
    discard "Empty"
    #> :q!

  check "RPC[Error]" notin output
