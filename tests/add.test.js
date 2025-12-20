import { loadWasm, runTest } from './utils.js';

async function runAllTests() {
  const wasm = await loadWasm('add');

  await runTest('Add Module', async (assert) => {
    assert.strictEqual(wasm.add(5, 3), 8, 'Add 5 + 3');
    assert.strictEqual(wasm.add(10, -7), 3, 'Add 10 + -7');
  });
}

runAllTests();