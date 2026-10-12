final: prev: {
  nimsight = final.mkNimbleApp {
    src = ./.;
    nimbleHash = "sha256-uFz7w43FN2kKC9HPi8IpxG0cIaiDJAh0A0enye6g0Cc=";

    checkInputs = [
      final.neovim # Tests use neovim
    ];

    preCheck = ''
      # Neovim needs to write some state
      export XDG_STATE_HOME=$(mktemp -d)
    '';

    meta = {
      description = "Language server for Nim based on `nim check`";
      homepage = "https://github.com/ire4ever1190/nimsight";
      license = final.lib.licenses.mit;
      mainProgram = "nimsight";
    };
  };
}
