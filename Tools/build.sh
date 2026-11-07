#!/bin/sh
# Builds the release (production) binary of FolioZero and copies it to the project root.
#
# Usage: Tools/build.sh [extra "swift build" options, e.g. --scratch-path <dir>]
# Result: ./foliozero, a single arm64 executable. Copy it to the headless Mac,
# e.g. to /usr/local/bin/foliozero.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

swift build -c release --product foliozero "$@"
bin_dir=$(swift build -c release --show-bin-path "$@")

install -m 755 "$bin_dir/foliozero" "$root/foliozero"
echo "Built $root/foliozero, version $("$root/foliozero" --version)"
