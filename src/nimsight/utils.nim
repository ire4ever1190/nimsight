import std/paths

func `/`*(a: Path, b: static[string]): Path = a / Path(b)

