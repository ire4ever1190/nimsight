## Few utilities to make working with locks nicer
import std/locks

## Simple helpers for usnig locks/condition variables

# Some of the comments are verbose since I was a lil confused when writing this

type
  ConditionVar* = object
    ## Condition variable and the kitchen sink.
    ## Only one place can wait on the condition
    lock: Lock
    cond: Cond

proc deinit*(x: ConditionVar) =
  deinitLock(x.lock)
  deinitCond(x.cond)

proc acquire*(x: var ConditionVar) =
  ## Locks the lock inside the condition variable
  x.lock.acquire()

proc release*(x: var ConditionVar) =
  ## Releases the lock inside the condition variable
  x.lock.release()

proc wait*(c: var ConditionVar, predicate: proc (): bool) {.effectsOf: predicate.} =
  ## Waits for the predicate to become true.
  ## Checks every time the condition is signaled.
  ## Is eager, if the predicate passes initially then it
  ## never waits on the condition.
  ##
  ## Condition variable is locked when `predicate` becomes true
  # Lock must be acquired so that its safe to check predicate.
  # man pages also said that it must be acquried before calling wait.
  acquire c
  while not predicate():
    wait(c.cond, c.lock)


proc signal*(c: var ConditionVar) =
  ## Signals for a **single** thread to check for the condition
  signal(c.cond)

proc broadcast*(c: var ConditionVar) =
  ## Signals for all threads to check for the condition
  broadcast(c.cond)

template withLock*(c: var ConditionVar, body: untyped) =
  ## Runs `body` with the condition variable locked
  try:
    acquire c
    body
  finally:
    release c
