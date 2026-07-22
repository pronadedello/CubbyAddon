#!/usr/bin/env bash
# Builds a release zip of the Cubby addon.
#
# Usage:  ./build.sh <output-dir>
#
# Produces:  <output-dir>/Cubby-<version>.zip
#
# The zip's top-level entry is `Cubby/` so that unzipping into
# `Interface/AddOns/` Just Works for the player. Only the files the
# WoW client actually loads (plus README.md and the icon) are
# included — dev tooling, installer script, generated PNGs, and the
# `.git*` plumbing are stripped, mirroring the `.pkgmeta` ignore list.
set -euo pipefail

out_dir="${1:?usage: build.sh <output-dir>}"
mkdir -p "$out_dir"

version=$(grep -E '^## Version:' Cubby.toc | awk '{print $NF}')
if [[ -z "$version" ]]; then
  echo "::error::could not read ## Version: from Cubby.toc" >&2
  exit 1
fi

# Stage into a temp dir whose top-level entry is `Cubby/` — that's
# the directory name `Cubby.toc` is keyed to, and the path the WoW
# client expects under Interface/AddOns/.
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
pkg_dir="$stage/Cubby"
mkdir -p "$pkg_dir"

# Whitelist what the WoW client loads, plus the icon and README.
# Keep this list in sync with the file list in Cubby.toc.
files=(
  Cubby.toc
  Build.lua
  Cubby.lua
  Buffs.lua
  UI.lua
  Tracker.lua
  Minimap.lua
  Restock.lua
  Bank.lua
  Cubby.tga
  README.md
)
for f in "${files[@]}"; do
  if [[ ! -f "$f" ]]; then
    echo "::error::missing expected file $f" >&2
    exit 1
  fi
  cp "$f" "$pkg_dir/$f"
done

zip_path="$out_dir/Cubby-$version.zip"
rm -f "$zip_path"
( cd "$stage" && zip -qr "$zip_path" Cubby )
echo "Built $zip_path"
ls -lh "$zip_path"
