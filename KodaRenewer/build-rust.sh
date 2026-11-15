#!/bin/bash
# Builds the Rust core for iPhones and for the simulator, and shows what came out.
# Run in KodaRenewer/. On Codemagic it is the "renewer-core" workflow.
set -euo pipefail
cd "$(dirname "$0")"

# Rust: use what is there, else install it. isideload needs a recent one.
if ! command -v cargo >/dev/null 2>&1; then
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
fi
# shellcheck disable=SC1091
[ -f "$HOME/.cargo/env" ] && source "$HOME/.cargo/env"
rustup update stable
rustup default stable
rustup target add aarch64-apple-ios aarch64-apple-ios-sim
# aws-lc (the crypto library idevice uses) is built with cmake.
command -v cmake >/dev/null 2>&1 || brew install cmake

rustc --version
cargo --version
xcodebuild -version

mkdir -p build
for target in aarch64-apple-ios aarch64-apple-ios-sim; do
  echo "== Building for $target"
  cargo build --release --target "$target"
  cp "target/$target/release/libkoda_renewer.a" "build/libkoda_renewer-$target.a"
done

ls -lh build
echo "== The entry point is in the library:"
nm -gU build/libkoda_renewer-aarch64-apple-ios.a | grep koda_renewer_ping
