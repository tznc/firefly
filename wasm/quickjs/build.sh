#!/bin/sh
# Rebuilds priv/plugins/quickjs.wasm (and its .sha256) in Docker, from the
# pinned QuickJS-ng commit and firefly_runtime.c. Run from anywhere:
#
#     wasm/quickjs/build.sh
#
# Set BASE_IMAGE to pull the Debian image from a mirror. The build is
# reproducible: rebuilding unchanged sources gives the committed checksum,
# which `FirestormWeb.Plugin.Sandboxed.Runtime` checks when it loads.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
out="$here/../../priv/plugins"
quickjs_tag=v0.18.0
quickjs_commit=d7215b0ad3fc2c562e8317fd9bca058fd4863804
image=firefly-quickjs-wasm

context=$(mktemp -d)
trap 'rm -rf "$context"; [ -z "${container:-}" ] || docker rm -f "$container" >/dev/null' EXIT

git -c advice.detachedHead=false clone -q --depth 1 --branch "$quickjs_tag" https://github.com/quickjs-ng/quickjs "$context/quickjs"
test "$(git -C "$context/quickjs" rev-parse HEAD)" = "$quickjs_commit"
rm -rf "$context/quickjs/.git"
cp "$here/Dockerfile" "$here/firefly_runtime.c" "$context/"

if [ -n "${BASE_IMAGE:-}" ]; then
  docker pull -q "$BASE_IMAGE" >/dev/null
  docker tag "$BASE_IMAGE" docker.io/debian:trixie-20261027-slim
fi

docker build -q -t "$image" "$context" >/dev/null
container=$(docker create "$image" /bin/true)
mkdir -p "$out"
docker cp -q "$container:/out/quickjs.wasm" "$out/quickjs.wasm"
(cd "$out" && sha256sum quickjs.wasm > quickjs.wasm.sha256)
cat "$out/quickjs.wasm.sha256"
