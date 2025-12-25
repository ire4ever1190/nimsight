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
            git
            cacert
          ];
          buildPhase = ''
            nimble -l setup
            ls
          '';

          installPhase = ''
            mv nimbledeps $out
          '';

          outputHashAlgo = "sha256";
          outputHashMode = "recursive";
          outputHash = "sha256-FheKWXMS7icRBY+E/l7NZVX1uZ4+KMBgY0yZ4lLPsT8=";
        };
      in
      {
        defaultPackage = pkgs.stdenv.mkDerivation {
          name = "nimsight";

          src = ./.;

          nativeBuildInputs = with pkgs; [
            nimble
            nim
            deps
            git
          ];

          buildPhase = ''
            export NIMBLE_DIR=${deps}
            nimble build
          '';

          installPhase = ''
            mkdir -p $out/bin
            mv nimsight $out/bin/nimsight
          '';
        };
        devShells = {
          default = pkgs.mkShellNoCC {
            packages = with pkgs; [
              nimble
            ];
          };
        };
      }
    );
}
