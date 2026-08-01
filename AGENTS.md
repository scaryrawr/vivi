# Vivi

## Project layout

- `apps/vivi/` — application crates (binaries, Tauri app)
- `crates/vivi-agent/` — shared library crates

## Tech stack

- Rust workspace (edition 2024, resolver "3")
- Tauri desktop framework
- Dioxus frontend

## Dev container

Uses `mcr.microsoft.com/devcontainers/base:noble` with Rust (wasm32 target), Node.js, and VS Code extensions: rust-analyzer, dependi, lldb, tauri-vscode, dioxus.

## Build

```bash
cargo build
cargo run
```
