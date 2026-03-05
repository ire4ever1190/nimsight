## Configuration for nimsight
import std/[options, json, jsonutils, os, files, sugar, paths, strformat]

import pkg/legit

type NimConfig* = object ## Configuration options for nimsight
  nimBinary*: Path
    ## Path to the Nim binary to use. If not set, will search PATH for "nim"
  nimbleBinary*: Path
    ## Path to the Nimble binary to use. If not set, will search PATH for "nimble"

proc initNimConfig(): NimConfig =
  ## Initialises the Nim config with defaults
  result = NimConfig(
    nimBinary: Path(findExe("nim")),
    nimbleBinary: Path(findExe("nimble"))
  )

let validBinary = validator[Path](
  path => path.fileExists(), path => fmt"'{$path}' does not point to a file"
)

let validator = NimConfig.validator()(
    nimBinary = @[validBinary],
    nimbleBinary = @[validBinary]
  )

proc parseConfig*(node: Option[JsonNode]): NimConfig =
  ## Parses configuration from initialization options
  var config = initNimConfig()
  node.map do(data: JsonNode):
    config.fromJson(data, JOptions(allowMissingKeys: true))

  # Check it makes sense
  let res = validator.validate(config)
  if res.isSome:
    # Not much we can do, just echo and exit
    echo res.get()
    quit QuitFailure
  return config
