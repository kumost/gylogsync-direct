#!/bin/bash
set -e

# Source Rust environment
source "$HOME/.cargo/env"

# Set ffmpeg paths for Homebrew
export PKG_CONFIG_PATH="/opt/homebrew/lib/pkgconfig:$PKG_CONFIG_PATH"
export FFMPEG_DIR="/opt/homebrew"

# Privacy: strip absolute host paths from the resulting .a debug info.
# Without this, cargo registry paths like /Users/<you>/.cargo/registry/...
# would be baked into the binary and leak when distributed publicly.
export RUSTFLAGS="${RUSTFLAGS:-} --remap-path-prefix=${HOME}/.cargo=/cargo --remap-path-prefix=${HOME}=/home --remap-path-prefix=$(pwd)=/source"

cd "$(dirname "$0")/rust-bridge"

echo "=== Building Rust bridge library ==="
echo "RUSTFLAGS: $RUSTFLAGS"

# Detect architecture
ARCH=$(uname -m)

if [ "$ARCH" = "arm64" ]; then
    echo "Building for aarch64-apple-darwin (Apple Silicon)..."
    cargo build --release --target aarch64-apple-darwin
    mkdir -p ../lib
    cp target/aarch64-apple-darwin/release/libgylogsync_bridge.a ../lib/
else
    echo "Building for x86_64-apple-darwin (Intel)..."
    cargo build --release --target x86_64-apple-darwin
    mkdir -p ../lib
    cp target/x86_64-apple-darwin/release/libgylogsync_bridge.a ../lib/
fi

echo "=== Rust bridge built successfully ==="
echo "Output: lib/libgylogsync_bridge.a"
ls -lh ../lib/libgylogsync_bridge.a
