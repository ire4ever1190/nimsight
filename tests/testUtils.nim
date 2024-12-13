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

suite "ref case":
  type
    Parent = ref object of RootObj
    ChildA = ref object of Parent
      foo: string
    ChildB = ref object of Parent
      bar: string
    ChildC = ref object of Parent
      foo: string

  test "Can access field":
    let x = Parent(ChildA(foo: "test"))
    var foo = ""
    case x:
    of ChildA:
      foo = x.foo
    else: discard
    check foo == "test"

  test "Can have multiple items":
    let x = Parent(ChildA(foo: "test"))
    var foo = ""
    case x:
    of ChildC, ChildA:
      foo = x.foo
    else: discard
    check foo == "test"

  test "Else branch works":
    let x = Parent(ChildB(bar: "test"))
    var foo = ""
    case x:
    of ChildC, ChildA:
      foo = x.foo
    else:
      foo = "no foo"
    check foo == "no foo"

  test "Can use in an expression":
    let x = Parent(ChildA(foo: "test"))
    let res = case x
      of ChildC, ChildA:
        x.foo
      else:
        "no foo"
    check res == "test"
