import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// Loads a WASM module and returns its exports
export async function loadWasm(moduleName, imports = {}) {
  const wasmPath = path.resolve(__dirname, '..', 'dist', `${moduleName}.wasm`);
  const wasmBytes = fs.readFileSync(wasmPath);
  const { instance } = await WebAssembly.instantiate(wasmBytes, imports);
  return instance.exports;
}

// Runs a test function with error handling and logging
export async function runTest(testName, testFunction) {
  console.log(`Running ${testName} tests...`);
  try {
    await testFunction(assert);
    console.log(`${testName} tests passed.`);
  } catch (error) {
    console.error(`${testName} tests failed:`, error.message);
    process.exit(1);
  }
}

