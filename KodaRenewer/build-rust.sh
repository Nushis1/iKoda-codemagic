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

# One XCFramework with both builds, so Xcode picks the right one for a phone or the simulator.
# Swift imports it as `import KodaRenewer` (include/module.modulemap).
rm -rf build/KodaRenewer.xcframework build/KodaRenewer.xcframework.zip
xcodebuild -create-xcframework \
  -library build/libkoda_renewer-aarch64-apple-ios.a -headers include \
  -library build/libkoda_renewer-aarch64-apple-ios-sim.a -headers include \
  -output build/KodaRenewer.xcframework
(cd build && zip -qry KodaRenewer.xcframework.zip KodaRenewer.xcframework)
echo "== XCFramework:"
find build/KodaRenewer.xcframework -maxdepth 2 | sort
head -40 build/KodaRenewer.xcframework/Info.plist

# Where the Swift package KodaRenewerKit looks for it (not in git).
rm -rf ../KodaRenewerKit/KodaRenewer.xcframework
cp -R build/KodaRenewer.xcframework ../KodaRenewerKit/KodaRenewer.xcframework

ls -lh build
echo "== The entry point is in the library:"
# Every exported entry point should be listed. Xcode's nm cannot read some of Rust's newer LLVM
# objects and exits with an error for them; that says nothing about our functions, so its exit
# code is ignored and only a missing function fails the build.
symbols=$(nm -gU build/libkoda_renewer-aarch64-apple-ios.a 2>/dev/null || true)
for name in koda_renewer_ping koda_renewer_init koda_renewer_login koda_renewer_account_free; do
  # A here-string, not `echo | grep -q`: grep -q stops at the first match, echo then gets SIGPIPE,
  # and with pipefail that made a present function look missing.
  if grep -q " T _$name\$" <<< "$symbols"; then
    echo "  ok  $name"
  else
    echo "  MISSING  $name"
    exit 1
  fi
done
