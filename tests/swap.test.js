import { loadWasm, runTest } from "./utils.js";

async function runAllTests() {
  const wasm = await loadWasm("swap");

  await runTest("Swap Module", async (assert) => {
    const memory = wasm.memory;
    const f64View = new Float64Array(memory.buffer);

    // Set initial values
    f64View[0] = 1.23; // Address 0
    f64View[1] = 4.56; // Address 8

    // Call swap function, passing byte offsets
    wasm.swap(0, 8);

    // Check if values are swapped
    assert.strictEqual(f64View[0], 4.56, "f64View[0] should be 4.56");
    assert.strictEqual(f64View[1], 1.23, "f64View[1] should be 1.23");
  });
}

runAllTests();
