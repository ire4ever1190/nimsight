{
  description = "Language server for Nim based around `nim check` instead of `nimsuggest`";

  inputs = {
    flake-utils.url = "github:numtide/flake-utils";
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    nim2nix = {
      url = "github:daylinmorgan/nim2nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      nim2nix,
      ...
    }@inputs:

    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ nim2nix.overlays.default ];
        };
      in
      {
        packages.default = pkgs.buildNimblePackage {
          pname = "nimsight";
          version = "0.2.0";
          src = ./.;
          nimbleDepsHash = "sha256-rvKzltujFyj8n+tvRFi8EE/ZStVokg67DEs2aa5GpYU=";

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
