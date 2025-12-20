import { loadWasm, runTest } from './utils.js';

async function runAllTests() {
  const wasm = await loadWasm('combined');

  await runTest('Combined Module', async (assert) => {
    assert.strictEqual(wasm.add(10, 5), 15, 'Add 10 + 5');
    assert.strictEqual(wasm.sub(10, 5), 5, 'Sub 10 - 5');

    // FFT tests
    const n = 4;
    const memory = wasm.memory;
    const data = new Float64Array(memory.buffer, 0, n * 2);

    // Input: [1, 1, 1, 1] (as complex numbers)
    data[0] = 1; data[1] = 0;
    data[2] = 1; data[3] = 0;
    data[4] = 1; data[5] = 0;
    data[6] = 1; data[7] = 0;

    wasm.fft(n);

    const results = new Float64Array(memory.buffer, 0, n * 2);

    // Expected output: [4, 0, 0, 0]
    const expected_real_4 = [4, 0, 0, 0];
    const expected_imag_4 = [0, 0, 0, 0];

    for (let i = 0; i < n; i++) {
      assert.strictEqual(results[i * 2].toPrecision(6), expected_real_4[i].toPrecision(6), `FFT N=4 Real[${i}]`);
      assert.strictEqual(results[i * 2 + 1].toPrecision(6), expected_imag_4[i].toPrecision(6), `FFT N=4 Imag[${i}]`);
    }

    const n_8 = 8;
    const data_8 = new Float64Array(memory.buffer, 0, n_8 * 2);

    // Input: [1, 1, 1, 1, 0, 0, 0, 0]
    for (let i = 0; i < n_8; i++) {
      if (i < 4) {
        data_8[i * 2] = 1;
      } else {
        data_8[i * 2] = 0;
      }
      data_8[i * 2 + 1] = 0;
    }

    wasm.fft(n_8);

    const results_8 = new Float64Array(memory.buffer, 0, n_8 * 2);

    // Expected output from python's numpy.fft.fft([1,1,1,1,0,0,0,0])
    const expected_real_8 = [4, 1, 0, 1, 0, 1, 0, 1];
    const expected_imag_8 = [0, -2.41421, -1, -0.414214, 0, 0.414214, 1, 2.41421];

    for (let i = 0; i < n_8; i++) {
      assert.strictEqual(results_8[i * 2].toPrecision(6), expected_real_8[i].toPrecision(6), `FFT N=8 Real[${i}]`);
      assert.strictEqual(results_8[i * 2 + 1].toPrecision(6), expected_imag_8[i].toPrecision(6), `FFT N=8 Imag[${i}]`);
    }
  });
}

runAllTests();