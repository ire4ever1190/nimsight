{
  description = "Language server for Nim based around `nim check` instead of `nimsuggest`";

  inputs = {
    flake-utils.url = "github:numtide/flake-utils";
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    nimbleUtils = {
      url = "github:ire4ever1190/mkNimbleApp";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      nimbleUtils,
      ...
    }@inputs:

    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        mkNimbleApp = nimbleUtils.packages.${system}.default.mkNimbleApp;
      in
      {
        packages.default = mkNimbleApp {
          src = ./.;
          nimbleHash = "sha256-QMO9V5nBhmDasT2Nxyb/rakClYCNBs31pa1AQj9lde0=";

          checkInputs = [
            pkgs.neovim # Tests use neovim
          ];

          preCheck = ''
            # Neovim needs to write some state
            export XDG_STATE_HOME=$(mktemp -d)
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
