#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
developer_dir="${DEVELOPER_DIR:-$(xcode-select -p)}"
developer_dir="${developer_dir%/}"
export DEVELOPER_DIR="$developer_dir"

# CLT's Testing.framework loads a companion dylib outside its framework folder.
# Link both locations into the test bundle before SwiftPM's helper loads it.
if [[ "$developer_dir" == */CommandLineTools ]]; then
  frameworks="$developer_dir/Library/Developer/Frameworks"
  libraries="$developer_dir/Library/Developer/usr/lib"
  if [[ ! -d "$frameworks/Testing.framework" || ! -f "$libraries/lib_TestingInterop.dylib" ]]; then
    printf '%s\n' 'Swift Testing runtime is incomplete. Repair the developer toolchain before testing.' >&2
    exit 1
  fi
  for argument in "$@"; do
    if [[ "$argument" == --skip-build ]]; then
      printf '%s\n' 'Do not skip the build with Command Line Tools: the test bundle must have the runtime paths.' >&2
      exit 1
    fi
  done
  flags=(-Xswiftc "-F$frameworks" -Xlinker "-F$frameworks"
    -Xlinker -rpath -Xlinker "$frameworks"
    -Xlinker -rpath -Xlinker "$libraries")
  exec swift test --package-path "$repo_root" "${flags[@]}" "$@"
fi

exec swift test --package-path "$repo_root" "$@"
