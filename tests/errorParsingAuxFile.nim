macro test(body: untyped): untyped =
  body

test:
  type
    Hello = object
      name = "Test"

  echo 'a'

template hello() =
  {.warning: "test".}
hello()

let world = "test"
echo worl
echo p
