{
  description = "Language server for Nim based around `nim check` instead of `nimsuggest`";

  inputs = {
    flake-utils.url = "github:numtide/flake-utils";
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      ...
    }@inputs:

    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        deps = pkgs.stdenv.mkDerivation {
          name = "deps";
          src = ./.;
          nativeBuildInputs = with pkgs; [
            nimble
            cacert
            # Needed for downloading different packages
            git
            mercurial
          ];
          buildPhase = ''
            export OUTPUT_DIR=$(mktemp -d)
            # Refresh now or else nimble will try and pull the list later
            nimble --nimbleDir=$OUTPUT_DIR refresh

            # Run setup to pull all the dependencies
            nimble --nimbleDir=$OUTPUT_DIR setup
          '';

          installPhase = ''
            mv $OUTPUT_DIR $out
          '';

          outputHashAlgo = "sha256";
          outputHashMode = "recursive";
          outputHash = "sha256-rTYinFvPJadOFrta4EGv9IUo92zv15QEJrTtm0VweWY=";
        };
      in
      {
        packages.default = pkgs.stdenv.mkDerivation {
          pname = "nimsight";
          version = "0.1.0";

          src = ./.;

          nativeBuildInputs = with pkgs; [
            nimble
            nim
            deps
          ];

          buildInputs = [
            pkgs.neovim # Tests use neovim
          ];

          buildPhase = ''
            export DEPS_DIR=$(mktemp -d)
            export NIMCACHE=$(mktemp -d)
            # Copy into a temp directory we can write to
            cp -r ${deps}/* $DEPS_DIR/

            # Nimble writes to this at the end for some reason
            chmod +rw $DEPS_DIR/nimbledata2.json

            nimble --nimbleDir=$DEPS_DIR --useSystemNim --nimcache:$NIMCACHE --nim:${pkgs.nim}/bin/nim --offline -d:release build
          '';

          doCheck = true;
          checkPhase = ''
            # Neovim needs to write some state
            export XDG_STATE_HOME=$(mktemp -d)
            nimble --nimbleDir=$DEPS_DIR --useSystemNim --nimcache:$NIMCACHE --nim:${pkgs.nim}/bin/nim --offline test
          '';

          installPhase = ''
            mkdir -p $out/bin
            mv nimsight $out/bin/nimsight
          '';
        };
        devShells = {
          default = pkgs.mkShell {
            packages = with pkgs; [
              nimble
              neovim
            ];
          };
        };
      }
    );
}
