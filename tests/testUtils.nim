import nim_lsp_sdk/utils

import std/[unittest, json, jsonutils]

type Idk = Union[(string, int)]

var a: Idk
fromJsonHook(a, newJInt(0))

suite "Mixin":
  type
    A = object
      world: int
    B = object
      hello: string
    C = ref object of mixed(A, B)
      child: int

  test "Fields work":
    let c = C(world: 9, hello: "foo", child: 2)
    check c.world == 9
    check c.hello == "foo"
    check c.child == 2

suite "Union":
    type
      Foo = object
        name: string
      Bar = object
        something: bool
      FooBar = Union[(Foo, Bar)]

    test "Can convert to single type":
      let x = Foobar.init(Foo(name: "idk"))
      check (x as Foo).name == "idk"

    test "Defect raised for invalid use":
      let x = FooBar.init(Bar(something: false))
      expect FieldDefect:
        discard x as Foo

    test "Test case statement":
      let x = Foobar.init(Foo(name: "test"))
      case x
      of Foo:
        check x.name == "test"
      of Bar:
        # Shouldn't happen
        check false

    test "Converting from JSON":
      var data = "{\"something\": true}".parseJson().jsonTo(FooBar)
      check (data as Bar).something
      data = "{\"name\": \"Jake\"}".parseJson().jsonTo(FooBar)
      check (data as Foo).name == "Jake"

    test "Converting to JSON":
      let
        foo = Foobar.init(Foo(name: "test"))
        data = foo.toJson()
      checkpoint data.pretty()
      check len(data) == 1
      check data["name"].getStr() == "test"

    test "Invalid JSON still fails":
      expect ValueError:
        discard newJInt(0).jsonTo(FooBar)
