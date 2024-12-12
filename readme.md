# Checkster ☑️

Nim LSP based around `nim check`. Has 70% less features and stability compared to other nim LSP solutions.

I first started programming Nim using [micro](https://github.com/zyedidia/micro) which just had a linter for Nim,
so I wanted that same experience in other editors. Doesn't support auto-complete and likely never will unless [the --suggest option starts working](https://github.com/nim-lang/Nim/blob/4f5c0efaf24e863b26b16d7998eac3bdd830e7be/compiler/commands.nim#L1004)

Tested with Kate, semi tested with NeoVim (I run the test suite
with it, but personally dont use it)


### Features

This is the list of features that are supported/will eventually be supported

- [x] Show errors/warnings
- [x] Show outline of document
- [x] Basic fixes for some errors
- [x] Nimble and nimscript files
- [ ] Go-to symbol definition (The code is there, but it basically never works)
- [ ] Find usages
- [ ] Rename symbol
- [ ] Code lens (Nimble tasks, run tests)

### Usage

#### Kate

Add this into the list of LSP servers
```json
{
  "nim": {
    "command": ["nim_lsp_sdk"],
    "path": ["%{ENV:HOME}/.nimble/bin", "%{ENV:USERPROFILE}/.nimble/bin"],
    "rootIndicationFilePatterns": ["*.nimble", "config.nims"],
    "url": "https://github.com/ire4ever1190/nimsight",
    "highlightingModeRegex": "Nim"
  }
}
```
