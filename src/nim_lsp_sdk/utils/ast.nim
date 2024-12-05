## Utils for working with the Nim AST
import "$nim"/compiler/[parser, ast, idents, options, msgs, pathutils, syntaxes, lineinfos, llstream]
import ../types

type ParsedFile* = tuple[idx: FileIndex, ast: PNode]

proc ignoreErrors(conf: ConfigRef; info: TLineInfo; msg: TMsgKind; arg: string) =
  # TODO: Don't ignore errors
  discard

proc parseFile*(x: DocumentUri, content: sink string): ParsedFile {.gcsafe.} =
  ## Parses a document. Doesn't perform any semantic analysis
  var conf = newConfigRef()
  let fileIdx = fileInfoIdx(conf, AbsoluteFile x)
  var p: Parser
  {.gcsafe.}:
    parser.openParser(p, fileIdx, llStreamOpen(content), newIdentCache(), conf)
    defer: closeParser(p)
    p.lex.errorHandler = ignoreErrors
    result = (fileIdx, parseAll(p))
