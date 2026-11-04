#!/usr/bin/env bash
# Move this fork onto the latest Ghostty release, rebuild and reinstall.
#
#   contrib/update-fork.sh
#
# 1. Fetches Ghostty's release tags from upstream.
# 2. If a newer vX.Y.Z exists, replays the fork's commits on top of it
#    (git rebase). On conflicts it stops so you can resolve them.
# 3. Installs the Zig version that release needs, if it changed.
# 4. Builds and installs to ~/.local, then pushes the branch to origin.
#
# Afterwards quit Ghostty completely (pkill -x ghostty) and reopen it.
set -euo pipefail

BRANCH=widget
PREFIX="$HOME/.local"
ZIG_DIR="$HOME/.local/zig"
ZIG="$ZIG_DIR/zig"

cd "$(git rev-parse --show-toplevel)"

if [ -n "$(git status --porcelain)" ]; then
  echo "You have uncommitted changes. Commit or stash them first." >&2
  exit 1
fi
git switch --quiet "$BRANCH"

git remote get-url upstream >/dev/null 2>&1 ||
  git remote add upstream https://github.com/ghostty-org/ghostty.git
echo "Fetching Ghostty releases..."
git fetch --quiet upstream --tags

latest=$(git tag -l 'v[0-9]*.[0-9]*.[0-9]*' --sort=-v:refname | head -1)
base=$(git describe --tags --abbrev=0 --match 'v[0-9]*.[0-9]*.[0-9]*' HEAD)

if [ "$latest" = "$base" ]; then
  echo "Already on the latest release ($base). Rebuilding anyway."
else
  echo "Moving the fork from $base to $latest..."
  if ! git rebase --onto "$latest" "$base" "$BRANCH"; then
    echo >&2
    echo "The fork's changes conflict with $latest." >&2
    echo "Fix the files git lists, then: git add <files> && git rebase --continue" >&2
    echo "and run this script again. To give up: git rebase --abort" >&2
    exit 1
  fi
fi

# Install the Zig version this release asks for.
need=$(sed -n 's/.*minimum_zig_version = "\(.*\)".*/\1/p' build.zig.zon)
have=$("$ZIG" version 2>/dev/null || echo none)
if [ "$need" != "$have" ]; then
  echo "Installing Zig $need (had $have)..."
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  curl -fsSL https://ziglang.org/download/index.json -o "$tmp/index.json"
  read -r url sha < <(python3 -I -c '
import json, sys
d = json.load(open(sys.argv[1]))[sys.argv[2]]["x86_64-linux"]
print(d["tarball"], d["shasum"])' "$tmp/index.json" "$need")
  curl -fSL --progress-bar "$url" -o "$tmp/zig.tar.xz"
  echo "$sha  $tmp/zig.tar.xz" | sha256sum -c --quiet -
  rm -rf "$ZIG_DIR" && mkdir -p "$ZIG_DIR"
  tar -xJf "$tmp/zig.tar.xz" -C "$ZIG_DIR" --strip-components=1
  ln -sf "$ZIG" "$HOME/.local/bin/zig"
fi

echo "Building and installing to $PREFIX..."
"$ZIG" build -Doptimize=ReleaseFast -p "$PREFIX"

echo "Pushing to origin..."
git push --quiet --force-with-lease origin "$BRANCH"
git push --quiet origin "$(git describe --tags --abbrev=0 --match 'v[0-9]*.[0-9]*.[0-9]*' HEAD)" 2>/dev/null || true

echo
echo "Done: $(./zig-out/bin/ghostty --version 2>/dev/null | head -1 || echo installed)."
echo "Quit Ghostty completely (pkill -x ghostty) and reopen it."
