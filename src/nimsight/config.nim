## Configuration for nimsight
import std/[options, json, jsonutils, os]

type
  NimConfig* = object
    ## Configuration options for nimsight
    nimBinary*: string
      ## Path to the Nim binary to use. If not set, will search PATH for "nim"
    nimbleBinary*: string
      ## Path to the Nimble binary to use. If not set, will search PATH for "nimble"

proc initNimConfig(): NimConfig =
  ## Initialises the Nim config with defaults
  result = NimConfig(
    nimBinary: findExe("nim"),
    nimbleBinary: findExe("nimble")
  )

proc validate(config: NimConfig) =
  ## Runs checks to ensure the config looks right
  if config.nimBinary == "":
    raise (ref CatchableError)(msg: "")

proc parseConfig*(node: Option[JsonNode]): NimConfig =
  ## Parses configuration from initialization options
  var config = initNimConfig()
  node.map do (data: JsonNode):
    config.fromJson(data, JOptions(allowMissingKeys: true))
  return config
