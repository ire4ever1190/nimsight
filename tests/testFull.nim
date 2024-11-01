import std/[osproc, streams, os, unittest, macros, strutils, strformat, strscans, paths]

proc readBlock(x: NimNode): string =
  ## Returns the block of code that corresponds to
  ## a NimNode. Only works on code thats in a source
  ## file (i.e. not macro generated code)
  let
    info = x.lineInfoObj
    lines = info.filename.readFile().splitLines()
    start = info.line - 1
  var commentOpen = false # Support #[ ]#
  # Find the line that the code ends on e.g. the indention levels go back up
  let indention = lines[start].indentation
  for i in start ..< lines.len:
    # When the indention changes, its a different block
    let
      line = lines[i]
      currIndent = line.strip(leading=false).indentation
      stripped = line.strip()
    # If the indention changes then break.
    # Because I am lazy I added support for open/close comments
    # and nothing else
    if currIndent notin [0, indention] and not commentOpen:
      break
    if stripped.endsWith("#["):
      commentOpen = true
    elif stripped.endsWith("]#"):
      commentOpen = true
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
  ##
  ## Commands can be stored inline by prefixing with `#>` e.g.
  ## ```
  ## #> :q
  ## ```
  ## Or point to a particular line, in this case the cursor will jump
  ## to the position before calling the command
  ## ```
  ## # This will move the cursor to the first 'e' then call :idk
  ## echo "hello" #[
  ##        ^ :idk ]#
  ## ```
  var i = 0
  let lines = x.splitLines()
  while i < lines.len:
    let line = lines[i]
    if line.startsWith("#> "):
      result &= line.replace("#> ", "")
    elif line.strip().endsWith("#["):
      i += 1
      let
        line = lines[i]
        col = line.indentation()
      result &= fmt":cal cursor({i}, {col})"
      let (ok, command) = line.strip().scanTuple("^$+]#")
      assert ok, line
      result &= command.strip()
    i += 1

proc nvimTest(path: string): string =
  # Write the code to a temp file to be read by the test
  let
    file = string(currentSourcePath.parentDir().Path / Path"scripts" / Path(path).changeFileExt("nim"))
    code = file.readFile()
    # Parse the commands. Make sure we always exit at the end
    commands = (code.parseCommands() & ":q!").join("\n")
  # Extract the commands from the source
  file.changeFileExt("vim").writeFile(commands)
  echo  file.changeFileExt("vim")

  runTest(file)


test "No errors on startup":
  let output = nvimTest("empty.nim")

  check "RPC[Error]" notin output
  check "error = " notin output

test "Can get diagnostics":
  let output = nvimTest("diagnosticPragmas")
  check "Warning is shown" in output
  check "Hint is shown" in output
  check "Error is shown" in output
  # Just a sanity check to make sure only the things
  # we point to
  check "Make sure the test works" notin output
