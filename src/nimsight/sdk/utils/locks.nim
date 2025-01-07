## Few utilities to make working with locks/threads nicer
import std/locks
import std/private/threadtypes

import pkg/threading/rwlock

# Some of the comments are verbose since I was a lil confused when writing this

type
  ConditionVar* = object
    ## Condition variable and the kitchen sink.
    ## Only one place can wait on the condition
    lock: Lock
    cond: Cond

  ProtectedVar*[T; L] = object
    ## Variable that is guarded by a lock.
    ## All accesses return a lock which guards access
    value: T
    lock: L

  ScopedRead = distinct ptr RwLock
  ScopedWrite = distinct ptr RwLock

  LockedVar[T, L] = tuple[value: T, lock: L]

proc `=dup`(l: ScopedRead): ScopedRead {.error: "Lock can only be moved".}

proc `=destroy`(l: ScopedRead) =
  (ptr RwLock)(l)[].endRead()

proc `=dup`(l: ScopedWrite): ScopedWrite {.error: "Lock can only be moved".}

proc `=destroy`(l: ScopedWrite) =
  (ptr RwLock)(l)[].endWrite()


proc get*[T, L](v: ProtectedVar[T, L]): LockedVar[lent T, L] =
  ## Gets the value stored in `v`
  result.lock = v.lock
  result.lock.lock()
  result.value = v.value

proc read*[T](v: var ProtectedVar[T, RwLock]): lent LockedVar[T, ScopedRead] =
  ## Grants read access to the variable.
  v.lock.beginRead()
  result.lock = ScopedRead(addr v.lock)
  result.value = v.value

proc write*[T](v: var ProtectedVar[T, RwLock]): LockedVar[var T, ScopedWrite] =
  ## Grants write access to the variable.
  v.lock.beginWrite()
  result.lock = ScopedWrite(addr v.lock)
  result.value = v.value

proc initProtectedVar*[T, L](v: sink T, lock: sink L): ProtectedVar[T, L] =
  result.value = v
  result.lock = lock


proc unsafeGet*[T, L](v: var ProtectedVar[T, L]): var T {.inline.} = v.value

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
