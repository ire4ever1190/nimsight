## Implements checking if a process is still running.
## Used for seeing if the client has closed

import std/os

proc isRunning*(pid: int): bool
  ## Checks if a process is running

when defined(windows):
  import std/winlean

  proc isRunning(pid: int): bool =
    # Windows impl based on https://stackoverflow.com/a/1591371/21247938
    var exitCode: int32
    let
      handle = openProcess(SYNCHRONIZE, WINBOOL(0), DWORD(pid))
      ret = getExitCodeProcess(handle, exitCode)
    if ret == 0:
      raise (ref OSError)(msg: "There was an error")

    return ret != STILL_ACTIVE
else:
  import std/[posix_utils, posix]

  proc isRunning(pid: int): bool =
    # From https://github.com/nim-lang/langserver/blob/0c287fe98603117df4742bcaf9d3027bb938808d/asyncprocmonitor.nim#L24C1-L26C16
    try:
      sendSignal(Pid(pid), 0)
      false
    except:
      true




