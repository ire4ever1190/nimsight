import nim_lsp_sdk/utils

import std/unittest


suite "Mixin":
  type
    A = object
      world: int
    B = object
      hello: string
    C = ref object of mixed(A, B)

  test "Fields work":
    let c = C(world: 9, hello: "foo")
    check c.world == 9
    check c.hello == "foo"
