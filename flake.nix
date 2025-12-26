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
          srcs = builtins.path {
            name = "nimsight";
            path = ./.;
          };
          nativeBuildInputs = with pkgs; [
            nimble
            cacert
            # Needed for downloading different packages
            git
            mercurial
          ];
          buildPhase = ''
            mkdir -p nimbledeps
            # Run setup to pull all the dependencies
            nimble --debug setup
          '';

          installPhase = ''
            mkdir -p $out
            mv nimbledeps $out/
            echo "[]" > $out/packages_official.json
            find $out -type f -exec sha256sum {} \;
          '';

          outputHashAlgo = "sha256";
          outputHashMode = "recursive";
          outputHash = "sha256-YMXN3cZFrtpCTX/1Iy1evUGBHkomFCPonRd3kAtC0ps=";
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

          checkInputs = [
            pkgs.neovim # Tests use neovim
          ];

          buildPhase = ''
            # Nimble wants to write its data into NIMBLE_DIR which by default is in ~/.nimble
            # We can't override NIMBLE_DIR, because then it wont use local dependencies
            export HOME=$(mktemp -d)

            # Copy into a temp directory we can write to
            cp -r ${deps}/nimbledeps .
            chmod +w nimbledeps/nimbledata2.json

            nimble --useSystemNim --nim:${pkgs.nim}/bin/nim --offline -d:release build
          '';

          doCheck = true;
          checkPhase = ''
            # Neovim needs to write some state
            export XDG_STATE_HOME=$(mktemp -d)
            nimble --useSystemNim --nim:${pkgs.nim}/bin/nim --offline test
          '';

          installPhase = ''
            mkdir -p $out/bin
            mv nimsight $out/bin/nimsight
          '';

          meta = {
            description = "Language server for Nim based on `nim check`";
            homepage = "https://github.com/ire4ever1190/nimsight";
            license = pkgs.lib.licenses.mit;
            mainProgram = "nimsight";
          };
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
