import std/paths

import files, sdk/server


func `/`*(a: Path, b: static[string]): Path = a / Path(b)

