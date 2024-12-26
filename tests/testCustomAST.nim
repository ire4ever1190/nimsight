import std/[unittest, macros, paths, os, dirs, options]

import nimsight/[customast, nim_check]
import nimsight/utils/ast

import "$nim"/compiler/[ast, parser, syntaxes, options, msgs, idents, pathutils]

let compilerPath = getCurrentCompilerExe().Path.parentDir().parentDir()/Path"compiler"

test "Can convert to/from":
  # Go through every file in the Nim install and check we can convert too and from.
  # Translation should be loseless
  for file in walkDirRec(compilerPath):
    if file.splitFile.ext == ".nim":
      checkpoint $file
      var conf = newConfigRef()
      let fileIdx = fileInfoIdx(conf, AbsoluteFile $file)
      let node = parseFile(fileIdx, newIdentCache(), conf).toTree()

      check node[].toPNode().toTree() == node
