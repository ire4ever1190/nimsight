## Simple helpers for working with locks.
## Not efficient, but makes life easier
import pkg/threading/rwlock

type
  ReadWriteLocked*[T] = object
    ## Data that is protected by a read/write lock.
    ## Provides structured access for properly calling read/write
    lock: RwLock
    data {.guard: lock.}: T

proc protectReadWrite*[T](init: T): ReadWriteLocked[T] =
  ReadWriteLocked[T](lock: createRwLock(), data: init)

template with*[T](l: var ReadWriteLocked[T], body: proc (data: var T)) =
  ## Write lock that is just a statement
  {.gcsafe.}:
    var ourLock = addr l
  writeWith ourLock[].lock:
    body(ourLock[].data)

template with*[T, R](l: var ReadWriteLocked[T], body: proc (data: var T): R): R =
  ## Write lock that can return a value
  block:
    {.gcsafe.}:
      let ourLock = addr l
    var val {.noinit.}: R
    writeWith ourLock[].lock:
      val = body(ourLock[].data)
    val
