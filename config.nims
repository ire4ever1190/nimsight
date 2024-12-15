switch("d", "nimsuggest") # To get endInfo on nodes
# There is issues when sending the request to a worker thread? Stacktrace says it appears in
# readRequest but that doesnt seem right. Anyways this fixes it so its definitely an orc + ref issue
switch("mm", "atomicArc")
warning("Uninit", off)
warning("ProveInit", off)
# begin Nimble config (version 2)
--noNimblePath
when withDir(thisDir(), system.fileExists("nimble.paths")):
  include "nimble.paths"
# end Nimble config
