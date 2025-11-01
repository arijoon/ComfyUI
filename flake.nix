{
  description = "Comfy flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/8b27c1239e5c421a2bbc2c65d52e4a6fbf2ff296";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let

        pkgs = import nixpkgs {
          inherit system;
          overlays = [ ];
          config = {
            allowUnfree = true;
          };
        };
        inherit (pkgs)
          writeScriptBin
          runCommand
          makeWrapper
          lib
          libGL
          libGLU
          ;
        # localPython = writeScriptBin "local-python" ''
        #   ./.venv/bin/python "$@"
        # '';

        # py = pkgs.python312.withPackages (pyPkgs: [

        # ]);

        # Wrap only python with the required lib files
        # python =
        #   runCommand "python"
        #     {
        #       nativeBuildInputs = [ makeWrapper ];
        #       buildInputs = [
        #         # libGL
        #         # libGLU
        #         localPython
        #       ];
        #     }
        #     ''
        #       makeWrapper ${localPython}/bin/local-python $out/bin/py \
        #        --prefix LD_LIBRARY_PATH : ${
        #          lib.makeLibraryPath [
        #            pkgs.stdenv.cc.cc
        #           #  libGL
        #           #  libGLU
        #            pkgs.glib
        #          ]
        #        }
        #     '';

        #  --prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath [pkgs.stdenv.cc.cc pkgs.cudaPackages.cudatoolkit pkgs.cudaPackages.cudnn libGL libGLU]}

        # makeVenv = writeScriptBin "make-venv" ''
        #   ${py}/bin/python -m venv ./.venv
        # '';

        run = writeScriptBin "run" ''
          uv run python main.py --base-directory /storage/industry/comfyui-base --output-directory ~/mnt/comfy/ --disable-metadata
        '';
      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = [
            pkgs.nixfmt-rfc-style
            run
            # makeVenv
            # python
          ];

          shellHook = ''
            if [ -d ".venv" ]; then
                # Check if the activate script exists
                if [ -f ".venv/bin/activate" ]; then
                    source .venv/bin/activate
                    echo "Virtual environment activated."
                else
                    echo "Error: venv exists but activation script is missing."
                fi
            else
                echo "No venv directory found."
            fi
          '';
        };
      }
    );
}
