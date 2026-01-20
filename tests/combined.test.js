import { loadWasm, runTest } from "./utils.js";

async function runAllTests() {
  const wasm = await loadWasm("combined");

  await runTest("Combined Module", async (assert) => {
    // FFT tests
    const n = 4;
    const memory = wasm.memory;
    const data = new Float64Array(memory.buffer, 0, n * 2);

    // Input: [1, 1, 1, 1] (as complex numbers)
    data[0] = 1;
    data[1] = 0;
    data[2] = 1;
    data[3] = 0;
    data[4] = 1;
    data[5] = 0;
    data[6] = 1;
    data[7] = 0;

    wasm.fft(n);

    const results = new Float64Array(memory.buffer, 0, n * 2);

    // Expected output: [4, 0, 0, 0]
    const expected_real_4 = [4, 0, 0, 0];
    const expected_imag_4 = [0, 0, 0, 0];

    for (let i = 0; i < n; i++) {
      const tolerance = 0.01;
      assert.ok(
        Math.abs(results[i * 2] - expected_real_4[i]) < tolerance,
        `FFT N=4 Real[${i}]: ${results[i * 2]} ≈ ${expected_real_4[i]}`,
      );
      assert.ok(
        Math.abs(results[i * 2 + 1] - expected_imag_4[i]) < tolerance,
        `FFT N=4 Imag[${i}]: ${results[i * 2 + 1]} ≈ ${expected_imag_4[i]}`,
      );
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

    // Expected output for FFT([1,1,1,1,0,0,0,0]) - verified by DFT calculation
    const expected_real_8 = [4, 1, 0, 1, 0, 1, 0, 1];
    const expected_imag_8 = [0, -2.414214, 0, -0.414214, 0, 0.414214, 0, 2.414214];

    // FFT accuracy with quadrant-reduced Taylor series
    for (let i = 0; i < n_8; i++) {
      const tolerance = 0.01; // Tight tolerance - quadrant reduction gives high accuracy
      assert.ok(
        Math.abs(results_8[i * 2] - expected_real_8[i]) < tolerance,
        `FFT N=8 Real[${i}]: ${results_8[i * 2].toFixed(6)} ≈ ${expected_real_8[i].toFixed(6)}`,
      );
      assert.ok(
        Math.abs(results_8[i * 2 + 1] - expected_imag_8[i]) < tolerance,
        `FFT N=8 Imag[${i}]: ${results_8[i * 2 + 1].toFixed(6)} ≈ ${expected_imag_8[i].toFixed(6)}`,
      );
    }
  });
}

runAllTests();
