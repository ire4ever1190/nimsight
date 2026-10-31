final: prev: {
  nimsight = final.mkNimbleApp {
    src = ./.;
    nimbleHash = "sha256-c/5uTvGi5//r7SqQ1W8okpoHETua55BT2rSk5DB4nP8=";

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
