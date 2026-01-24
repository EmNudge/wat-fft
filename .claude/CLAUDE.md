# Project Instructions

## Before Starting New Work

Read the README.md to understand the project context, structure, and conventions.

## Keeping Documentation in Sync

If you make changes that would cause the README to be inaccurate (new features, changed APIs, modified build steps, etc.), update the README.md accordingly.

## WebAssembly Tooling

Prefer `wasm-tools` over WABT tools:

- Use `wasm-tools parse` instead of `wat2wasm`
- Use `wasm-tools print` instead of `wasm2wat`
- Use `wasm-tools validate` instead of `wasm-validate`
