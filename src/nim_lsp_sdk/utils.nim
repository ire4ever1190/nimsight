import std/macrocache


const rpcDecl = CacheTable"lsp.rpcParams"
  ## Mapping of method name to param/return type

const rpcNotifications = CacheTable"lsp.rpcReturns"
  ## Table of methods that are notifications.
  ## Just in case there is a method that returns null

macro rpcParam*(name: static[string], typ: typed) =
  ## Marks a type as being the param from a method
