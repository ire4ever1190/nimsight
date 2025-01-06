## Very basic union macro.
## Compiles the list of types into a variant object.
## The dispatching leaves room for improvement, currently is basically a linear search.
## Doesn't support fancy types yet (generics)
# Just was kinda interested on how to make one so implemented it instead of using a library

import std/[macros, sugar, json, jsonutils]

macro createUnion(x: typedesc): untyped =
  var names: seq[(NimNode, NimNode)]
  let types = x.getTypeInst()[1]
  for i, x in types:
    if x.kind != nnkSym:
      "All types passed must be syms".error(x)
    # Maybe quote to handle generics?
    names &= (genSym(nskField, "Field" & $i), x)

  let
    # We use a range type instead of creating an enum
    rangeType = nnkInfix.newTree(ident"..", newLit 0, newLit types.len - 1)
    objIdent = genSym(nskType, "obj")
    discrimField = genSym(nskField, "discrim")

  # Generate all the branches in the object
  let branches = collect:
    for i, typ in types:
      # For simplicity sake, I also export the fields
      # TODO: Don't require exporting fields
      nnkOfBranch.newTree(newLit i, nnkRecList.newTree(
        newIdentDefs(nnkPostfix.newTree(ident"*", ident "Field" & $i), typ)))

  # Combine it all to make the object
  result = nnkTypeSection.newTree(
    nnkTypeDef.newTree(
      objIdent,
      newEmptyNode(),
      nnkObjectTy.newTree(
        newEmptyNode(),
        newEmptyNode(),
        nnkRecList.newTree(
          nnkRecCase.newTree(newIdentDefs(nnkPostfix.newTree(ident"*", discrimField), rangeType))
          .add(branches)
        )
      )
    )
  )
  result = result[0][2]

{.experimental: "dynamicBindSym".}
macro oneOf*(x: typedesc): typedesc =
  ## Unpacks a tuple type into a series of
  ## or statements. Useful for generic programming
  ## where you want a parameter constrained to a union
  let types = x.getTypeInst()[1]
  result = bindSym($types[0])
  for typ in types[1..^1]:
    result = nnkInfix.newTree(bindSym"|", result, bindSym($typ, brOpen))

type
  Union*[T] = createUnion(T)
    ## Used as a typeclass for writing generic
    ## functions that accept unions

  OneOf*[T] = oneOf(T)
    ## Used to unpack a tuple type into `A | B | C`.
    ## Useful for generic programming

template getCurrentField(x: Union, body: untyped) =
  ## Returns the current field.
  var first = true
  for field, value in x.fieldPairs:
    if not first:
      var it {.inject.} = value
      body
    first = false

proc `$`*[T](x: Union[T]): string =
  ## Forwards the `$` to the current type
  x.getCurrentField():
    return $it

macro `case`*[T: Union](obj: T): untyped =
  ## Provides structured access to a union.
  ## This is the only provided mechanism so that we don't
  ## run into any runtime safety issues
  let variable = obj[0]
  if variable.kind != nnkSym:
    "Can only match on a variable, not an expression".error(variable)
  var whenStmt = nnkWhenStmt.newTree()
  for branch in obj[1..^1]:
    if branch[0].kind != nnkIdent:
      "Selector must be a single type".error(branch)
    # Add in a new symbol that is the union restricted to the single type
    var body = newStmtList()
    body &= newLetStmt(ident $variable, ident"it")
    body &= branch[1]
    whenStmt &= nnkElifBranch.newTree(nnkInfix.newTree(ident"is", ident"it", branch[0]), body)
  result = newCall(bindSym"getCurrentField", variable, whenStmt)

proc `as`*[T, V](obj: T, to: typedesc[V]): V =
  ## Unpacks a union to be a single type.
  ## Raises `FieldDefect` if the type doesn't match'
  obj.getCurrentField:
    when type(it) isnot V:
      raise (ref FieldDefect)(msg: "Can't use obj as " & $V)
    else:
      return it

proc types(x: NimNode): seq[tuple[field: NimNode, typ: NimNode]] =
  ## Returns all the types of a union in order
  let
    recCase = x.getType[1][2][0]
  for branch in recCase[1..^1]:
    result &= (branch[1][0], branch[1][0].getTypeInst())

proc discriminator(x: NimNode): NimNode =
  ## Returns the discriminator field
  x.getType[1][2][0][0]

macro branches*(typ: typedesc, body: untyped) =
  ## Unrolls the body into each type
  let
    recCase = typ.getType[1][2][0]
    discrim = recCase[0]
  result = newStmtList()
  for (_, typ) in typ.types:
    let tempName = ident"it"
    let typeTemplate = quote do:
      type `tempName` = `typ`
    result &= newBlockStmt(newEmptyNode(), newStmtList(typeTemplate, body.copy()))

macro init*[T: Union, V](x: typedesc[T], val: V): untyped =
  ## Initialises a union with a value
  for i, (field, typ) in x.types:
    if typ.sameType(val):
      return nnkObjConstr.newTree(
        x,
        nnkExprColonExpr.newTree(x.discriminator, newLit i),
        nnkExprColonExpr.newTree(field, val)
      )
  ("Type cannot be assigned to this union: " & $V).error(val)

# Implement JSON hooks

proc fromJsonHook*(a: var Union, b: JsonNode, opt = JOptions()) =
  ## Goes through each type branch in the union and attempts to parse from JSON.
  ## First type that passes is used
  type U = type(a)
  branches(type(a)):
    var val: it
    try:
      val.fromJson(b, opt)
      a = U.init(val)
      return
    except JsonKindError, JsonParsingError, ValueError:
      discard
  raise (ref ValueError)(msg: "Unable to parse " & $U)

proc toJsonHook*(a: Union, opt = initToJsonOptions()): JsonNode =
  a.getCurrentField:
    return it.toJson(opt)
