{ sources ? import ./nix/sources.nix }:
let
  pkgs = import sources.nixpkgs {
    overlays = [ ];
    config = {
      allowUnfree = true;
    };
  };
  inherit (pkgs) writeScriptBin runCommand makeWrapper lib libGL libGLU;
  localPython = writeScriptBin "local-python"
    ''
      ./venv/bin/python "$@"
    '';

  py = pkgs.python312.withPackages (pyPkgs: [

  ]);

  # Wrap only python with the required lib files
  python =
    runCommand "python"
      {
        nativeBuildInputs = [ makeWrapper ];
        buildInputs = [ libGL libGLU localPython ];
      } ''
      makeWrapper ${localPython}/bin/local-python $out/bin/py \
       --prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath [pkgs.stdenv.cc.cc libGL libGLU pkgs.glib]}
    '';

      #  --prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath [pkgs.stdenv.cc.cc pkgs.cudaPackages.cudatoolkit pkgs.cudaPackages.cudnn libGL libGLU]}

  makeVenv = writeScriptBin "make-venv"
    ''
      ${py}/bin/python -m venv ./venv
    '';

  run = writeScriptBin "run"
    ''
      ${python}/bin/py main.py --base-directory ~/data/comfy-base --output-directory /mnt/l/comfy/ --disable-metadata

    '';
in
{
  inherit pkgs python makeVenv py;
  deps = [
  ];

  shell = pkgs.mkShell {
    buildInputs = [
      python
      makeVenv
      run
    ];

    shellHook = ''
      if [ -d "venv" ]; then
          # Check if the activate script exists
          if [ -f "venv/bin/activate" ]; then
              source venv/bin/activate
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
