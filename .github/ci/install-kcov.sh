#!/bin/sh
# Ubuntu 24.04 does not ship kcov. Build the pinned release into KCOV_PREFIX.
set -eu
prefix="${KCOV_PREFIX:?}"
sudo apt-get update
sudo apt-get install -y cmake ninja-build pkg-config binutils-dev \
    libcurl4-openssl-dev libdw-dev libelf-dev zlib1g-dev
src=$(mktemp -d)
git clone --depth 1 --branch v43 https://github.com/SimonKagstrom/kcov.git "$src"
cmake -S "$src" -B "$src/build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$prefix"
cmake --build "$src/build"
cmake --install "$src/build"
