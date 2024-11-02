import std/[osproc, streams, os, unittest, macros, strutils, strformat, strscans, paths]


proc checkDiff(inputFile: string) =
  ## Checks the output file matches what we expect
  let
    file = Path(inputFile)
    expected = file.changeFileExt("expected")
    actual = file.changeFileExt("out")
  # Run diff on them
  let process = startProcess("diff", args = [$expected, $actual], options={poStdErrToStdOut, poUsePath})
  defer: process.close()
  let code = process.waitForExit()
  checkpoint process.outputStream.readAll()
  assert code == QuitSuccess

proc runTest(inputFile: string): string =
  ## Runs a neovim test
  # Start the neovim process
  let configFile = currentSourcePath.parentDir() / "config.lua"
  let p = startProcess(
    "nvim", args=["nvim", "-n", "--clean", "--headless", "-u", $configFile, inputFile],
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
  # We also want to check the output file (if applicable)
  checkDiff(inputFile)

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

proc getCommands(path: string): seq[string] =
  ## Returns all the commands that should be called for a file
  result = path.readFile.parseCommands()
  # If there is an expected file, then save
  if fileExists($path.Path.changeFileExt(".expected")):
    result &= ":w! " & $path.Path.changeFileExt("out")
  # Always exit
  result &= ":q!"

proc nvimTest(path: string): string =
  # Write the code to a temp file to be read by the test
  let
    file = string(currentSourcePath.parentDir().Path / Path"scripts" / Path(path).changeFileExt("nim"))
    # Parse the commands. Make sure we always exit at the end
    commands = file.getCommands()
  # Extract the commands from the source
  file.changeFileExt("vim").writeFile(commands.join("\n"))

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

suite "Code actions":
  test "Function rename":
    discard nvimTest("codeAction")
