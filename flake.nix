{
  description = "Comfy flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    pyproject-nix = {
      url = "github:pyproject-nix/pyproject.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    uv2nix = {
      url = "github:pyproject-nix/uv2nix";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    pyproject-build-systems = {
      url = "github:pyproject-nix/build-system-pkgs";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.uv2nix.follows = "uv2nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      pyproject-nix,
      uv2nix,
      pyproject-build-systems,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };
        inherit (pkgs) lib;

        python = pkgs.python312;

        workspace = uv2nix.lib.workspace.loadWorkspace {
          workspaceRoot = ./.;
          pyproject = lib.importTOML ./pyproject.local.toml;
          uvLock = lib.importTOML ./uv.lock;
        };

        overlay = workspace.mkPyprojectOverlay {
          sourcePreference = "wheel";
        };

        # Helper: find nvidia sub-package lib dirs inside a derivation
        nvLibSearchPath = pkg: ''
          for dir in ${pkg}/${python.sitePackages}/nvidia/*/lib; do
            [ -d "$dir" ] && addAutoPatchelfSearchPath "$dir"
          done
        '';

        # Collect all available nvidia packages from the overlay for torch's search paths.
        # These are the pip-bundled CUDA runtime libs (cublas, cudnn, etc.).
        nvidiaPkgNames = [
          "nvidia-cublas"
          "nvidia-cuda-cupti"
          "nvidia-cuda-nvrtc"
          "nvidia-cuda-runtime"
          "nvidia-cudnn-cu13"
          "nvidia-cufft"
          "nvidia-cufile"
          "nvidia-curand"
          "nvidia-cusolver"
          "nvidia-cusparse"
          "nvidia-cusparselt-cu13"
          "nvidia-nccl-cu13"
          "nvidia-nvjitlink"
          "nvidia-nvshmem-cu13"
          "nvidia-nvtx"
        ];

        cudaOverlay =
          final: prev:
          let
            available = builtins.filter (n: builtins.hasAttr n prev) nvidiaPkgNames;

            # Search paths for torch: all nvidia packages (none reference torch, so no cycle)
            torchNvSearchPaths = lib.concatMapStringsSep "\n" (
              n: nvLibSearchPath (builtins.getAttr n final)
            ) available;

          in
          lib.optionalAttrs (prev ? torch) {
            torch = prev.torch.overrideAttrs (old: {
              buildInputs = (old.buildInputs or [ ]) ++ [
                pkgs.stdenv.cc.cc.lib
              ];
              autoPatchelfIgnoreMissingDeps = (old.autoPatchelfIgnoreMissingDeps or [ ]) ++ [
                "libcuda.so.1"
              ];
              preFixup = (old.preFixup or "") + torchNvSearchPaths;
            });
          }
          // lib.optionalAttrs (prev ? torchvision) {
            torchvision = prev.torchvision.overrideAttrs (old: {
              preFixup =
                (old.preFixup or "")
                + ''
                  addAutoPatchelfSearchPath ${final.torch}/${python.sitePackages}/torch/lib
                ''
                + torchNvSearchPaths;
            });
          }
          // lib.optionalAttrs (prev ? torchaudio) {
            torchaudio = prev.torchaudio.overrideAttrs (old: {
              preFixup =
                (old.preFixup or "")
                + ''
                  addAutoPatchelfSearchPath ${final.torch}/${python.sitePackages}/torch/lib
                ''
                + torchNvSearchPaths;
            });
          }
          // lib.optionalAttrs (prev ? nvidia-cusparse) {
            nvidia-cusparse = prev.nvidia-cusparse.overrideAttrs (old: {
              preFixup =
                (old.preFixup or "")
                + lib.optionalString (prev ? nvidia-nvjitlink) (nvLibSearchPath final.nvidia-nvjitlink);
            });
          }
          // lib.optionalAttrs (prev ? nvidia-cusolver) {
            nvidia-cusolver = prev.nvidia-cusolver.overrideAttrs (old: {
              preFixup =
                (old.preFixup or "")
                + lib.optionalString (prev ? nvidia-nvjitlink) (nvLibSearchPath final.nvidia-nvjitlink)
                + lib.optionalString (prev ? nvidia-cusparse) (nvLibSearchPath final.nvidia-cusparse)
                + lib.optionalString (prev ? nvidia-cublas) (nvLibSearchPath final.nvidia-cublas);
            });
          }
          // lib.optionalAttrs (prev ? nvidia-cufile) {
            nvidia-cufile = prev.nvidia-cufile.overrideAttrs (old: {
              buildInputs = (old.buildInputs or [ ]) ++ [ pkgs.rdma-core ];
            });
          }
          // lib.optionalAttrs (prev ? nvidia-nvshmem-cu13) {
            nvidia-nvshmem-cu13 = prev.nvidia-nvshmem-cu13.overrideAttrs (old: {
              buildInputs = (old.buildInputs or [ ]) ++ [
                pkgs.ucx
                pkgs.rdma-core
              ];
              autoPatchelfIgnoreMissingDeps = (old.autoPatchelfIgnoreMissingDeps or [ ]) ++ [
                "libmpi*"
                "libpmix*"
                "libfabric*"
                "liboshmem*"
              ];
            });
          }
          // lib.optionalAttrs (prev ? nvidia-cudnn-cu13) {
            nvidia-cudnn-cu13 = prev.nvidia-cudnn-cu13.overrideAttrs (old: {
              # libcudnn.so.9 dlopen's sub-libraries at runtime but they aren't DT_NEEDED,
              # so auto-patchelf won't add the self-dir. Append to auto-patchelf's array
              # in preFixup so it's included when auto-patchelf runs in postFixup.
              preFixup = (old.preFixup or "") + ''
                appendRunpaths+=("$out/${python.sitePackages}/nvidia/cudnn/lib")
              '';
            });
          }
          // lib.optionalAttrs (prev ? onnxruntime-gpu) {
            onnxruntime-gpu = prev.onnxruntime-gpu.overrideAttrs (old: {
              autoPatchelfIgnoreMissingDeps = (old.autoPatchelfIgnoreMissingDeps or [ ]) ++ [
                "libcublas.so.*"
                "libcublasLt.so.*"
                "libcudart.so.*"
                "libcudnn.so.*"
                "libcufft.so.*"
                "libcurand.so.*"
                "libnvinfer.so.*"
                "libnvonnxparser.so.*"
              ];
              preFixup = (old.preFixup or "") + torchNvSearchPaths;
            });
          }
          // lib.optionalAttrs (prev ? pyopengl) {
            pyopengl = prev.pyopengl.overrideAttrs (old: {
              buildInputs = (old.buildInputs or [ ]) ++ [ pkgs.libGL ];
            });
          }
          // lib.optionalAttrs (prev ? glfw) {
            glfw = prev.glfw.overrideAttrs (old: {
              buildInputs = (old.buildInputs or [ ]) ++ [ pkgs.glfw3 ];
            });
          };

        # ComfyUI is run from source, not installed as a package.
        # Override it to produce an empty site-packages entry while preserving
        # its dependency metadata so mkVirtualEnv still pulls in all deps.
        comfyuiOverlay =
          _final: prev:
          lib.optionalAttrs (prev ? comfyui) {
            comfyui = prev.comfyui.overrideAttrs (_old: {
              dontUnpack = true;
              dontBuild = true;
              nativeBuildInputs = [ ];
              installPhase = "mkdir -p $out/${python.sitePackages}";
            });
          };

        # Some sdist packages need setuptools/wheel but don't declare it
        buildFixesOverlay =
          final: prev:
          let
            needsSetuptools = [
              "antlr4-python3-runtime"
              "fvcore"
              "iopath"
              "sam2"
            ];
            fix =
              name:
              lib.nameValuePair name (
                prev.${name}.overrideAttrs (old: {
                  nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [
                    final.setuptools
                    final.wheel
                  ];
                })
              );
          in
          builtins.listToAttrs (map fix (builtins.filter (n: prev ? ${n}) needsSetuptools));

        # All opencv variants provide cv2 — alias them to avoid collisions
        opencvOverlay =
          final: prev:
          lib.optionalAttrs (prev ? opencv-python-headless) {
            opencv-python-headless = final.opencv-python;
          }
          // lib.optionalAttrs (prev ? opencv-contrib-python) {
            opencv-contrib-python = final.opencv-python;
          };

        pythonSet = (pkgs.callPackage pyproject-nix.build.packages { inherit python; }).overrideScope (
          lib.composeManyExtensions [
            pyproject-build-systems.overlays.default
            overlay
            cudaOverlay
            comfyuiOverlay
            buildFixesOverlay
            opencvOverlay
          ]
        );

        # Reads requirements.txt + requirements.local.txt + mod requirements,
        # patches pyproject.toml with deps + CUDA index,
        # writes the result to pyproject.local.toml (upstream pyproject.toml stays untouched).
        syncScript = pkgs.writeText "sync-deps.py" ''
          import re
          import os
          import glob

          def normalize(name):
              return re.split(r'[><=~!\[;@]', name.strip())[0].strip().lower().replace('-', '_').replace(' ', "")

          def read_reqs(path):
              lines = []
              try:
                  with open(path) as f:
                      for l in f:
                          l = l.strip()
                          if l and not l.startswith('#') and not l.startswith('git+'):
                              lines.append(l)
              except FileNotFoundError:
                  pass
              return lines

          skip_pkgs = {
              'torch', 'torchvision', 'torchaudio', 'torchsde',
              'onnxruntime',
              'opencv_python', 'opencv_python_headless', 'opencv_contrib_python',
          }

          deps = read_reqs("requirements.txt")
          deps += read_reqs("requirements.local.txt")

          seen = set(normalize(d) for d in deps)

          base_dir = os.path.join(os.path.dirname(os.path.abspath(".")), "comfyui-base")
          mod_reqs = sorted(glob.glob(os.path.join(base_dir, "custom_nodes", "*", "requirements.txt")))
          for req_file in mod_reqs:
              mod_name = os.path.basename(os.path.dirname(req_file))
              if mod_name.endswith('.disabled'):
                  continue
              for line in read_reqs(req_file):
                  norm = normalize(line)
                  if norm not in seen and norm not in skip_pkgs:
                      seen.add(norm)
                      deps.append(line)
                      print(f"  + {line} (from {mod_name})")

          with open("pyproject.toml") as f:
              content = f.read()

          content = re.sub(
              r"^dependencies\s*=\s*\[.*?\][ \t]*\n",
              "",
              content,
              flags=re.DOTALL | re.MULTILINE,
          )

          content = re.sub(r"^\[tool\.uv\.sources\]\n(?:(?!\[).*\n)*\n?", "", content, flags=re.MULTILINE)
          content = re.sub(r"^\[\[tool\.uv\.index\]\]\n(?:(?!\[).*\n)*\n?", "", content, flags=re.MULTILINE)

          deps_block = "dependencies = [\n"
          for dep in deps:
              deps_block += f'    "{dep}",\n'
          deps_block += "]\n"

          content = re.sub(
              r'(requires-python\s*=\s*"[^"]*"\n)',
              lambda m: m.group(0) + deps_block,
              content,
          )

          uv_block = (
              "[tool.uv.sources]\n"
              'torch = [{ index = "pytorch-cu130" }]\n'
              'torchvision = [{ index = "pytorch-cu130" }]\n'
              'torchaudio = [{ index = "pytorch-cu130" }]\n'
              "\n"
              "[[tool.uv.index]]\n"
              'name = "pytorch-cu130"\n'
              'url = "https://download.pytorch.org/whl/cu130"\n'
              "explicit = true\n"
              "\n"
          )

          if "[tool.ruff]" in content:
              content = content.replace("[tool.ruff]", uv_block + "[tool.ruff]")
          else:
              content = content.rstrip() + "\n\n" + uv_block

          content = re.sub(r"\n{3,}", "\n\n", content)

          with open("pyproject.local.toml", "w") as f:
              f.write(content)

          print("Wrote pyproject.local.toml")
        '';

        syncDeps = pkgs.writeShellScriptBin "sync-deps" ''
          set -euo pipefail
          cd "$(git rev-parse --show-toplevel)"
          ${python}/bin/python3 ${syncScript}
          # uv requires pyproject.toml — swap in ours, lock, then restore
          cp pyproject.toml pyproject.toml.upstream
          trap 'mv pyproject.toml.upstream pyproject.toml' EXIT
          cp pyproject.local.toml pyproject.toml
          # Use a temp cache dir to avoid stale .git files in ~/.cache/uv
          UV_CACHE_DIR="$(mktemp -d)" UV_PYTHON=${python}/bin/python3 ${pkgs.uv}/bin/uv lock --prerelease=allow
          echo "Done. Re-enter 'nix develop' to pick up changes."
        '';

        auditScript = pkgs.writeText "audit-deps.py" ''
          import json, re, sys, urllib.request

          with open("uv.lock") as f:
              content = f.read()

          blocks = re.split(r"\n(?=\[\[package\]\])", content)
          pkgs = {}
          for b in blocks:
              nm = re.search(r'^name = "(.+?)"', b, re.M)
              ver = re.search(r'^version = "(.+?)"', b, re.M)
              if nm and ver:
                  pkgs[nm.group(1)] = ver.group(1)

          print(f"Auditing {len(pkgs)} packages against OSV database...")

          queries = [
              {"package": {"name": n, "ecosystem": "PyPI"}, "version": v}
              for n, v in pkgs.items()
          ]
          req = urllib.request.Request(
              "https://api.osv.dev/v1/querybatch",
              data=json.dumps({"queries": queries}).encode(),
              headers={"Content-Type": "application/json"},
              method="POST",
          )
          results = json.loads(urllib.request.urlopen(req, timeout=30).read())["results"]

          names = list(pkgs.keys())
          total = 0
          for i, r in enumerate(results):
              vulns = r.get("vulns", [])
              if not vulns:
                  continue
              name, ver = names[i], pkgs[names[i]]
              print(f"\n  {name}=={ver}")
              for v in vulns:
                  total += 1
                  vid = v.get("id", "?")
                  try:
                      d = json.loads(urllib.request.urlopen(
                          f"https://api.osv.dev/v1/vulns/{vid}", timeout=10
                      ).read())
                      summary = d.get("summary", d.get("details", "No summary")[:200])
                      severity = [s.get("score", "?") for s in d.get("severity", [])]
                      fixed = []
                      for a in d.get("affected", []):
                          for rng in a.get("ranges", []):
                              for e in rng.get("events", []):
                                  if "fixed" in e:
                                      fixed.append(e["fixed"])
                      print(f"    {vid}: {summary}")
                      print(f"      Severity: {severity}")
                      print(f"      Fixed in: {', '.join(fixed) if fixed else 'No fix yet'}")
                  except Exception:
                      print(f"    {vid}: (could not fetch details)")

          if total == 0:
              print("\nNo known vulnerabilities found.")
          else:
              print(f"\n{total} vulnerability(ies) found.")
              sys.exit(1)
        '';

        auditDeps = pkgs.writeShellScriptBin "audit-deps" ''
          set -euo pipefail
          cd "$(git rev-parse --show-toplevel)"
          ${python}/bin/python3 ${auditScript}
        '';

        run = pkgs.writeScriptBin "run" ''
          python main.py --base-directory /storage/industry/comfyui-base --output-directory ~/mnt/comfy/ "$@"
        '';
      in
      {
        devShells.default =
          let
            virtualenv = pythonSet.mkVirtualEnv "comfyui-dev-env" workspace.deps.default;
          in
          pkgs.mkShell {
            packages = [
              virtualenv
              pkgs.uv
              pkgs.nixfmt
              syncDeps
              auditDeps
              run
            ];

            env = {
              UV_NO_SYNC = "1";
              UV_PYTHON_DOWNLOADS = "never";
            };

            shellHook = ''
              unset PYTHONPATH
              export REPO_ROOT=$(git rev-parse --show-toplevel)

              # Build a narrow lib directory with only NVIDIA driver libs.
              # This lets torch find libcuda.so.1 via LD_LIBRARY_PATH without
              # polluting the path with all of /usr/lib (which breaks nix binaries).
              _nvidia_libs="$REPO_ROOT/venv-nvidia-libs"
              if [ ! -d "$_nvidia_libs" ] || [ /usr/lib/libcuda.so.1 -nt "$_nvidia_libs" ]; then
                rm -rf "$_nvidia_libs"
                mkdir -p "$_nvidia_libs"
                for f in /usr/lib/libcuda.so* /usr/lib/libnvidia*.so*; do
                  [ -e "$f" ] && ln -sf "$f" "$_nvidia_libs/$(basename "$f")"
                done
              fi
              export LD_LIBRARY_PATH="$_nvidia_libs''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
              unset _nvidia_libs
            '';
          };

        packages.sync-deps = syncDeps;
        packages.audit-deps = auditDeps;
      }
    );
}
