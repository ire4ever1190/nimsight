switch("d", "nimsuggest") # To get endInfo on nodes
# There is issues when sending the request to a worker thread? Stacktrace says it appears in
# readRequest but that doesnt seem right. Anyways this fixes it so its definitely an orc + ref issue
switch("mm", "atomicArc")
