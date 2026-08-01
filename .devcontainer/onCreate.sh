#!/usr/bin/env bash

set -euo pipefail

# Install the Linux dependencies required by Tauri and Dioxus.
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  build-essential \
  curl \
  file \
  libayatana-appindicator3-dev \
  libgtk-3-dev \
  libssl-dev \
  libwebkit2gtk-4.1-dev \
  libxdo-dev \
  librsvg2-dev \
  patchelf \
  wget

# Use each crate's published lockfile to avoid incompatible transitive updates.
cargo install --locked --version 1.57.0 just
cargo install --locked --version 2.11.4 tauri-cli
cargo install --locked --version 0.7.10 dioxus-cli
