import { loadWasm, runTest } from './utils.js';

async function runAllTests() {
  const wasm = await loadWasm('math_trig');

  await runTest('Math Trig Module', async (assert) => {
    const PI = 3.141592653589793;

    // Test cos function - use appropriate tolerance for Taylor series
    assert.ok(Math.abs(wasm.cos(0) - 1) < 0.001, 'cos(0) ≈ 1');
    assert.ok(Math.abs(wasm.cos(PI / 2) - 0) < 0.005, 'cos(π/2) ≈ 0');
    assert.ok(Math.abs(wasm.cos(PI) - (-1)) < 0.01, 'cos(π) ≈ -1');
    assert.ok(Math.abs(wasm.cos(3 * PI / 2) - 0) < 0.03, 'cos(3π/2) ≈ 0');
    assert.ok(Math.abs(wasm.cos(2 * PI) - 1) < 0.001, 'cos(2π) ≈ 1');

    // Test sin function - use appropriate tolerance for Taylor series
    assert.ok(Math.abs(wasm.sin(0) - 0) < 0.001, 'sin(0) ≈ 0');
    assert.ok(Math.abs(wasm.sin(PI / 2) - 1) < 0.005, 'sin(π/2) ≈ 1');
    assert.ok(Math.abs(wasm.sin(PI) - 0) < 0.01, 'sin(π) ≈ 0');
    assert.ok(Math.abs(wasm.sin(3 * PI / 2) - (-1)) < 0.03, 'sin(3π/2) ≈ -1');
    assert.ok(Math.abs(wasm.sin(2 * PI) - 0) < 0.001, 'sin(2π) ≈ 0');

    // Test angle normalization (implicit in the functions)
    assert.ok(Math.abs(wasm.cos(2 * PI) - wasm.cos(0)) < 0.001, 'cos(2π) ≈ cos(0)');
    assert.ok(Math.abs(wasm.sin(2 * PI) - wasm.sin(0)) < 0.001, 'sin(2π) ≈ sin(0)');

    // Test globals
    assert.strictEqual(wasm.PI.value, PI, 'PI constant');
    assert.strictEqual(wasm.TWO_PI.value, 2 * PI, '2π constant');

    // Test for various angles - Taylor series is most accurate for small angles
    const testAngles = [0.1, 0.5, 1.0, PI / 4, PI / 3, PI / 6];
    testAngles.forEach(angle => {
      const tolerance = angle < 2 ? 0.001 : 0.01; // More lenient for larger angles
      assert.ok(Math.abs(wasm.cos(angle) - Math.cos(angle)) < tolerance, `cos(${angle.toFixed(3)}) is accurate`);
      assert.ok(Math.abs(wasm.sin(angle) - Math.sin(angle)) < tolerance, `sin(${angle.toFixed(3)}) is accurate`);
    });
  });
}

runAllTests();
