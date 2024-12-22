import ../[customast, server, params]
import std/[options, logging]

type
  CodeActionProvider = proc (
    handle: RequestHandle,
    params: CodeActionParams,
    ast: Tree,
    node: NodeIdx): seq[CodeAction]
    ## Code action provider can return a list of actions that can be applied to a node.
    ## `nodes` is the list of nodes that match the range specified in `params`


var providers: seq[CodeActionProvider]

proc registerProvider*(x: CodeActionProvider) =
  ## Registers a provider that will be queired by [getCodeActions].
  providers &= x

proc getCodeActions*(h: RequestHandle, params: CodeActionParams): seq[CodeAction] =
  ## Returns all code actions that apply to a code action request.
  # First find the node that action is referring to
  let root = h.parseFile(params.textDocument.uri)
  let node = root.ast[].findNode(params.range)
  if node.isNone:
    error "Could not find a node for this codeAction"
    return

  # Now run every provider, getting the list of actions
  {.gcsafe.}:
    debug "Running providers: ", len(providers)
    for provider in providers:
      result &= provider(h, params, root.ast, node.unsafeGet())
