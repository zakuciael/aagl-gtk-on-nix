[private]
@default:
    just --list

[private]
update_nix_pkg nix_file lock_file old_version new_version:
    #!/usr/bin/env python3
    from concurrent.futures import ThreadPoolExecutor
    from os import path
    from pathlib import Path
    from collections.abc import Callable
    from pathlib import Path
    from typing import IO, Any
    import subprocess
    import tomllib
    import json
    import fileinput
    import re
    import os
    import sys

    def run(
        command: list[str],
        cwd: Path | str | None = None,
        stdout: None | int | IO[Any] = subprocess.PIPE,
        stderr: None | int | IO[Any] = None,
        check: bool = True,
        extra_env: dict[str, str] = {},
    ) -> "subprocess.CompletedProcess[str]":
        env = os.environ.copy()
        env.update(extra_env)
        return subprocess.run(
            command, cwd=cwd, check=check, text=True, capture_output = True, env=env
        )

    def git_prefetch(x: tuple[str, tuple[str, str]]) -> tuple[str, str]:
      rev, (key, url) = x
      res = run(["nix-prefetch-git", url, rev, "--fetch-submodules"])
      return key, to_sri(json.loads(res.stdout)["sha256"])

    def to_sri(hashstr: str) -> str:
      if "-" in hashstr:
          return hashstr
      length = len(hashstr)
      if length == 32:
          prefix = "md5:"
      elif length == 40:
          # could be also base32 == 32, but we ignore this case and hope no one is using it
          prefix = "sha1:"
      elif length == 64 or length == 52:
          prefix = "sha256:"
      elif length == 103 or length == 128:
          prefix = "sha512:"
      else:
          return hashstr

      cmd = [
          "nix",
          "--extra-experimental-features",
          "nix-command",
          "hash",
          "to-sri",
          f"{prefix}{hashstr}",
      ]
      proc = run(cmd)
      return proc.stdout.rstrip("\n")

    def print_hashes(hashes: dict[str, str], indent: str) -> None:
      if not hashes:
        return
      print(f"{indent}outputHashes = {{{{")
      for k, v in hashes.items():
        print(f'{indent}  "{k}" = "{v}";')

      print(f"{indent}}};")

    def replace_version(nix_file: str, old_version: str, new_version: str) -> bool:
      with fileinput.FileInput(nix_file, inplace=True) as f:
        for line in f:
          print(line.replace(f'"{old_version}"', f'"{new_version}"'), end="")

    def update_cargo_lock(nix_file: str, lock_file: str) -> None:
      with open(lock_file, "rb") as f:
        hashes = {}
        lock = tomllib.load(f)
        regex = re.compile(r"git\+([^?]+)(\?(rev|tag|branch)=.*)?#(.*)")
        git_deps = {}
        for pkg in lock["package"]:
          if source := pkg.get("source"):
            if match := regex.fullmatch(source):
              rev = match[4]
              if rev not in git_deps:
                git_deps[rev] = f"{pkg['name']}-{pkg['version']}", match[1]

        for k, v in ThreadPoolExecutor().map(git_prefetch, git_deps.items()):
            hashes[k] = v

      with fileinput.FileInput(nix_file, inplace=True) as f:
        short = re.compile(r"(\s*)cargoLock\.lockFile\s*=\s*(.+)\s*;\s*")
        expanded = re.compile(r"(\s*)lockFile\s*=\s*(.+)\s*;\s*")

        for line in f:
          if match := short.fullmatch(line):
            indent = match[1]
            path = match[2]
            print(f"{indent}cargoLock = {{{{")
            print(f"{indent}  lockFile = {path};")
            print_hashes(hashes, f"{indent}  ")
            print(f"{indent}}};")
            for line in f:
              print(line, end="")
            return
          elif match := expanded.fullmatch(line):
            indent = match[1]
            path = match[2]
            print(line, end="")
            print_hashes(hashes, indent)
            brace = 0
            for line in f:
              for c in line:
                if c == "{":
                  brace -= 1
                if c == "}":
                  brace += 1
                if brace == 1:
                  print(line, end="")
                  for line in f:
                    print(line, end="")

                  return
          else:
            print(line, end="")

    if __name__ == "__main__":
      replace_version("{{nix_file}}", "{{old_version}}", "{{new_version}}")
      update_cargo_lock("{{nix_file}}", "{{lock_file}}")

[private]
get_nix_pkgs:
  #!/usr/bin/env -S nix eval --impure --json --file
  let
    lib = (import <nixpkgs> {}).lib;
    inherit (builtins) getFlake stringLength substring map;
    inherit (lib) getName;
    currentSystem = builtins.currentSystem;
    flake = getFlake "{{ invocation_directory() }}";
    inherit (flake) outPath;
    outPathLen = stringLength outPath;
    launchers = flake.packages.${currentSystem}.allLaunchers.paths;
    sanitizePosition = { file, ... }@pos:
        assert substring 0 outPathLen file != outPath
          -> throw "${file} is not in ${outPath}";
        pos // { file = "{{ invocation_directory() }}" + substring outPathLen (stringLength file - outPathLen) file; };
    getPosition = pkg: let
        raw_version_position = sanitizePosition (builtins.unsafeGetAttrPos "version" pkg);
        position = if pkg ? isRubyGem then
          raw_version_position
        else if pkg ? isPhpExtension then
          raw_version_position
        else
          sanitizePosition (builtins.unsafeGetAttrPos "src" pkg);
      in position;
    getCargoLock = pkg: if pkg ? cargoDeps.lockFile then
      let
        inherit (pkg.cargoDeps) lockFile;
        res = builtins.tryEval (sanitizePosition {
          file = toString lockFile;
        });
      in
      if res.success then res.value.file else false
    else
      null;
    getMetadata = pkg: let
      unwrapped = pkg.unwrapped;
      position = getPosition unwrapped;
      cargo_lock = getCargoLock unwrapped;
      package = unwrapped.src.repo;
    in {
      inherit (pkg) version;
      inherit (position) file;
      inherit cargo_lock package;
      name = pkg.pname;
    };
  in map getMetadata (builtins.filter (v: v.pname != "anime-games-launcher") launchers)

[private]
get_nix_pkg_version package:
  #!/usr/bin/env -S nix eval --impure --raw --file
  let
    inherit (builtins) getFlake;
    currentSystem = builtins.currentSystem;
    flake = getFlake "{{ invocation_directory() }}";
  in flake.packages.${currentSystem}.{{package}}.unwrapped.version

[doc('Create a patch file for a specified launcher')]
create_patch package nix_file cargo_lock:
    #!/usr/bin/env bash
    set -o errexit
    set -o nounset
    set -o pipefail
    # set -o xtrace

    BUILD=$(mktemp -u -q 'XXXXXXXXXX')
    TMP_FOLDER="/tmp/aagl-nix-patcher-${BUILD}"
    OUTPUT_FOLDER=$(dirname "{{nix_file}}")

    NIX_PKG_VERSION=$(just get_nix_pkg_version {{package}})
    SEMVER_PKG_VERSION=$(semver get release "${NIX_PKG_VERSION}")
    NEW_PKG_VERSION=$(semver bump build "${BUILD}" ${SEMVER_PKG_VERSION})

    ORG_FILES_PATH="${TMP_FOLDER}/org_files"
    MODIFIED_FILES_PATH="${TMP_FOLDER}/modified"
    PATCH_FILE_PATH="${TMP_FOLDER}/sdk.patch"
    CARGO_DEPS=( "anime-launcher-sdk" "anime-game-core" )
    FILES=( "Cargo.lock" "Cargo.toml" )

    echo "Creating temp folders.."
    echo "Temp folder: ${TMP_FOLDER}/"
    mkdir -p "${ORG_FILES_PATH}"
    mkdir -p "${MODIFIED_FILES_PATH}"

    for FILE in "${FILES[@]}"; do
        echo "Downloading ${FILE} file for {{package}} (${SEMVER_PKG_VERSION}).."
        curl "https://raw.githubusercontent.com/an-anime-team/{{package}}/${SEMVER_PKG_VERSION}/${FILE}" \
            -o "${ORG_FILES_PATH}/$FILE" \
            -s --fail --fail-early
    done

    echo "Fetching latest SDK revision.."
    SDK_REV=$(curl "https://api.github.com/repos/zakuciael/${CARGO_DEPS[0]}/commits/main" -s --fail --fail-early | dasel -r json -w yaml ".sha")
    echo "SDK revision: ${SDK_REV}"

    echo "Patching dependencies.."
    cp "${ORG_FILES_PATH}/${FILES[1]}" "${MODIFIED_FILES_PATH}/${FILES[1]}"
    FEATURES=$(dasel \
      -f "${MODIFIED_FILES_PATH}/${FILES[1]}" \
      -w json \
      --pretty=false \
      '.dependencies.anime-launcher-sdk.features')
    dasel put \
        -f "${MODIFIED_FILES_PATH}/${FILES[1]}" \
        -t json \
        -v '{ "name": "{{ snakecase(package) }}", "path": "src/lib.rs" }' \
        ".lib"
    dasel put \
        -f "${MODIFIED_FILES_PATH}/${FILES[1]}" \
        -t json \
        -v "{ \"git\": \"https://github.com/zakuciael/${CARGO_DEPS[0]}\", \"rev\": \"${SDK_REV}\", \"features\": ${FEATURES} }" \
        ".dependencies.anime-launcher-sdk"

    echo "Generating Cargo.lock file.."
    cargo generate-lockfile --manifest-path "${MODIFIED_FILES_PATH}/${FILES[1]}"

    echo "Generating patch file.."
    dasel delete \
        -f "${MODIFIED_FILES_PATH}/${FILES[1]}" \
        ".lib"
    diff -Naur "${ORG_FILES_PATH}/" "${MODIFIED_FILES_PATH}/" > "${PATCH_FILE_PATH}" || true

    echo "Moving files to the repository.."
    cp "${PATCH_FILE_PATH}" "${OUTPUT_FOLDER}"
    cp "${MODIFIED_FILES_PATH}/${FILES[0]}" "{{cargo_lock}}"

    echo "Updating nix package.."
    echo "Current version: ${NIX_PKG_VERSION}"
    echo "New version: ${NEW_PKG_VERSION}"
    just update_nix_pkg "{{nix_file}}" "{{cargo_lock}}" "${NIX_PKG_VERSION}" "${NEW_PKG_VERSION}"

    echo "Cleaning up temp directory.."
    # rm -rf "${TMP_FOLDER}"

    echo "Update complete!"

[doc('Create patch files for all launchers')]
patch:
  #!/usr/bin/env python3
  from concurrent.futures import ThreadPoolExecutor
  from os import path
  from pathlib import Path
  from collections.abc import Callable
  from pathlib import Path
  from typing import IO, Any
  import subprocess
  import tomllib
  import json
  import fileinput
  import re
  import os
  import sys

  def run(
      command: list[str],
      cwd: Path | str | None = None,
      stdout: None | int | IO[Any] = subprocess.PIPE,
      stderr: None | int | IO[Any] = None,
      check: bool = True,
      capture_output: bool = True,
      extra_env: dict[str, str] = {},
  ) -> "subprocess.CompletedProcess[str]":
      env = os.environ.copy()
      env.update(extra_env)
      return subprocess.run(
          command, cwd=cwd, check=check, text=True, capture_output=capture_output, env=env
      )

  def update_pkg(data: dict[str, str]) -> None:
    name = data['name']
    print(f"Updating {name}..")
    run(["just", "create_patch", data['package'], data['file'], data['cargo_lock']])

  if __name__ == "__main__":
    res = run(["just", "get_nix_pkgs"])
    data = json.loads(res.stdout)

    for v in ThreadPoolExecutor().map(update_pkg, data):
      None