#!/usr/bin/env bash
# Common test helper -- load bats-support and bats-assert from the first
# available location:  system-wide (CI runners) or ~/.local (macOS dev).

_load_lib() {
  local lib="$1"
  local dir
  for dir in /usr/lib/bats "${HOME}/.local/lib/bats"; do
    if [[ -f "${dir}/${lib}/load.bash" ]]; then
      load "${dir}/${lib}/load.bash"
      return
    fi
  done
  printf "ERROR: could not find %s\n" "$lib" >&2
  printf "Install with: git clone https://github.com/bats-core/%s ~/.local/lib/bats/%s\n" "$lib" "$lib" >&2
  return 1
}

_load_lib bats-support
_load_lib bats-assert
