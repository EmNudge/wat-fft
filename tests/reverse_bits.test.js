import { loadWasm, runTest } from './utils.js';

async function runAllTests() {
  const wasm = await loadWasm('reverse_bits');

  await runTest('Reverse Bits Module', async (assert) => {
    // n=8 (log2n=3)
    assert.strictEqual(wasm.reverse_bits(0, 3), 0, '000 -> 000 (0)');
    assert.strictEqual(wasm.reverse_bits(1, 3), 4, '001 -> 100 (4)');
    assert.strictEqual(wasm.reverse_bits(2, 3), 2, '010 -> 010 (2)');
    assert.strictEqual(wasm.reverse_bits(3, 3), 6, '011 -> 110 (6)');
    assert.strictEqual(wasm.reverse_bits(4, 3), 1, '100 -> 001 (1)');
    assert.strictEqual(wasm.reverse_bits(5, 3), 5, '101 -> 101 (5)');
    assert.strictEqual(wasm.reverse_bits(6, 3), 3, '110 -> 011 (3)');
    assert.strictEqual(wasm.reverse_bits(7, 3), 7, '111 -> 111 (7)');

    // n=4 (log2n=2)
    assert.strictEqual(wasm.reverse_bits(0, 2), 0, '00 -> 00 (0)');
    assert.strictEqual(wasm.reverse_bits(1, 2), 2, '01 -> 10 (2)');
    assert.strictEqual(wasm.reverse_bits(2, 2), 1, '10 -> 01 (1)');
    assert.strictEqual(wasm.reverse_bits(3, 2), 3, '11 -> 11 (3)');
  });
}

runAllTests();