{ pkgs }:
let
  # Function that creates a derivation containing the dependencies for a nimble project.
  # Can be copied into a folder called `nimbledeps` inside a project to give it isolated dependencies
  getNimbleDeps =
    { src, hash }:
    pkgs.stdenv.mkDerivation {
      name = "deps";
      src = src;
      nativeBuildInputs = with pkgs; [
        nimble
        cacert
        # Needed for downloading different packages
        git
        mercurial

        jq
      ];
      buildPhase = ''
        mkdir -p nimbledeps
        # Run setup to pull all the dependencies
        nimble setup

        # Sometimes the files listed in each nimblemeta.json file is in a different order.
        # We'll sort that so the hash is consistent
        for file in $(find -name nimblemeta.json); do
          jq '.metaData.files |= sort' "$file" > "$file.tmp"
          mv "$file.tmp" "$file"
        done
      '';

      installPhase = ''
        cp -r nimbledeps $out
      '';

      outputHashAlgo = "sha256";
      outputHashMode = "recursive";
      outputHash = hash;
    };

  # Returns the output of `nimble dump` in a structured format
  getNimbleMetadata =
    { src }:
    builtins.fromJSON (
      builtins.readFile (
        pkgs.stdenv.mkDerivation {
          name = "metadata";
          nativeBuildInputs = with pkgs; [
            nimble
            jq
          ];
          src = src;
          installPhase = ''
            # We need to delete nimDir since it refers to a store path
            nimble -l --offline dump --json --silent | jq 'del(.nimDir)' > $out
          '';
        }
      )
    );
in
{
  mkNimbleApp =
    userArgs:
    let
      metadata = getNimbleMetadata { src = userArgs.src; };
      deps = getNimbleDeps {
        src = userArgs.src;
        hash = userArgs.nimbleHash;
      };
    in
    pkgs.stdenv.mkDerivation (
      {
        pname = (metadata.name);
        version = metadata.version;

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
          cp -r ${deps} nimbledeps
          chmod +w nimbledeps/nimbledata2.json

          nimble --useSystemNim --nim:${pkgs.nim}/bin/nim --offline -d:release build
        '';

        doCheck = true;
        checkPhase = ''
          runHook preCheck

          nimble --useSystemNim --nim:${pkgs.nim}/bin/nim --offline test

          runHook postCheck
        '';

        installPhase = ''
          runHook preInstall

          mkdir -p $out/bin
          # Find all the binary files listed
          for binary in "${builtins.concatStringsSep " " metadata.bin}"; do
              mv $binary $out/bin/$binary
          done

          runHook postInstall
        '';
      }
      // userArgs
    );
}
