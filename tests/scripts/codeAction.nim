#> :w
#> :wait textDocument/publishDiagnostics

proc bamboo() = discard

bambo() #[
  ^ :CodeAction ]#


# Imports
import strutils #[
        ^ :CodeAction ]#
import std/[parseopt, strformat, macrocache] #[
             ^ :CodeAction ]#
import std/[parseopt, strformat, macrocache] #[
                        ^ :CodeAction ]#
import std/[parseopt, strformat, macrocache] #[
                                    ^ :CodeAction ]#
import strutils, macros #[
          ^ :CodeAction ]#


#> :wait TextChanged
