import { loadWasm, runTest } from './utils.js';

async function runAllTests() {
  const wasm = await loadWasm('sub');

  await runTest('Sub Module', async (assert) => {
    assert.strictEqual(wasm.sub(5, 3), 2, 'Sub 5 - 3');
    assert.strictEqual(wasm.sub(3, 5), -2, 'Sub 3 - 5');
  });
}

runAllTests();