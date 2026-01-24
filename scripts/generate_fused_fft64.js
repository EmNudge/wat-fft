#!/usr/bin/env node
/**
 * Generate a fully fused FFT-64 codelet
 *
 * This eliminates all function calls by inlining:
 * - fft_64's first stage (32 butterflies with W_64^k)
 * - fft_32's first stages at offsets 0 and 512 (16 butterflies each with W_32^k)
 * - fft_16 at offsets 0, 256, 512, 768 (fully fused radix-4)
 */

// Twiddle factor: W_N^k = cos(-2πk/N) + i*sin(-2πk/N) = (cos, sin) where sin is negative
function twiddle(N, k) {
  const angle = (-2 * Math.PI * k) / N;
  return {
    re: Math.cos(angle),
    im: Math.sin(angle),
  };
}

// Format number for WAT
function fmt(x) {
  // Handle special cases
  if (x === 0) return "0.0";
  if (x === 1) return "1.0";
  if (x === -1) return "-1.0";
  return x.toPrecision(17);
}

// Generate butterfly with twiddle multiplication
// DIF butterfly: a' = a + b, b' = (a - b) * W
function generateButterfly(k, N, offsetA, offsetB) {
  const w = twiddle(N, k);
  const lines = [];

  // Load a and b
  lines.push(`    ;; k=${k}: W_${N}^${k} = (${fmt(w.re)}, ${fmt(w.im)})`);
  lines.push(`    (local.set $a (v128.load (i32.const ${offsetA})))`);
  lines.push(`    (local.set $b (v128.load (i32.const ${offsetB})))`);

  if (k === 0) {
    // W = 1, no multiplication needed
    lines.push(`    (v128.store (i32.const ${offsetA}) (f64x2.add (local.get $a) (local.get $b)))`);
    lines.push(`    (v128.store (i32.const ${offsetB}) (f64x2.sub (local.get $a) (local.get $b)))`);
  } else if (w.re === 0 && Math.abs(w.im + 1) < 1e-10) {
    // W = -i (k = N/4), multiply by -i = swap and negate imaginary
    lines.push(`    (local.set $t (f64x2.sub (local.get $a) (local.get $b)))`);
    lines.push(`    (v128.store (i32.const ${offsetA}) (f64x2.add (local.get $a) (local.get $b)))`);
    lines.push(
      `    (v128.store (i32.const ${offsetB}) (f64x2.mul (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $t) (local.get $t)) (v128.const f64x2 1.0 -1.0)))`,
    );
  } else {
    // General case: complex multiplication
    // (a - b) * (re + i*im) where complex number is (re, im)
    // Result: (re*x - im*y, re*y + im*x) for input (x, y)
    // Using SIMD: result = t*re + shuffle(t)*im * (-1, 1)
    lines.push(`    (local.set $t (f64x2.sub (local.get $a) (local.get $b)))`);
    lines.push(`    (v128.store (i32.const ${offsetA}) (f64x2.add (local.get $a) (local.get $b)))`);
    lines.push(`    (v128.store (i32.const ${offsetB}) (f64x2.add`);
    lines.push(`      (f64x2.mul (local.get $t) (v128.const f64x2 ${fmt(w.re)} ${fmt(w.re)}))`);
    lines.push(
      `      (f64x2.mul (f64x2.mul (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $t) (local.get $t)) (v128.const f64x2 ${fmt(w.im)} ${fmt(w.im)})) (v128.const f64x2 -1.0 1.0))))`,
    );
  }

  return lines.join("\n");
}

// Generate fft_16 code for a specific base offset
function generateFFT16(baseOffset) {
  const lines = [];

  lines.push(`    ;; ========== FFT-16 at offset ${baseOffset} ==========`);

  // Load all 16 complex numbers
  for (let i = 0; i < 16; i++) {
    lines.push(`    (local.set $y${i} (v128.load (i32.const ${baseOffset + i * 16})))`);
  }

  // Stage 1: Four radix-4 butterflies (indices 0,4,8,12), (1,5,9,13), (2,6,10,14), (3,7,11,15)
  lines.push(`\n    ;; Stage 1: Four radix-4 butterflies`);
  for (let j = 0; j < 4; j++) {
    const i0 = j,
      i1 = j + 4,
      i2 = j + 8,
      i3 = j + 12;
    lines.push(`    (local.set $t0 (f64x2.add (local.get $y${i0}) (local.get $y${i2})))`);
    lines.push(`    (local.set $t1 (f64x2.sub (local.get $y${i0}) (local.get $y${i2})))`);
    lines.push(`    (local.set $t2 (f64x2.add (local.get $y${i1}) (local.get $y${i3})))`);
    lines.push(`    (local.set $t3 (f64x2.sub (local.get $y${i1}) (local.get $y${i3})))`);
    lines.push(
      `    (local.set $t3 (f64x2.mul (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $t3) (local.get $t3)) (v128.const f64x2 1.0 -1.0)))`,
    );
    lines.push(`    (local.set $y${i0} (f64x2.add (local.get $t0) (local.get $t2)))`);
    lines.push(`    (local.set $y${i1} (f64x2.add (local.get $t1) (local.get $t3)))`);
    lines.push(`    (local.set $y${i2} (f64x2.sub (local.get $t0) (local.get $t2)))`);
    lines.push(`    (local.set $y${i3} (f64x2.sub (local.get $t1) (local.get $t3)))`);
    lines.push(``);
  }

  // Stage 2: Apply twiddles and radix-4 butterflies
  // Twiddles for elements in position 4-7 (W_16^1, W_16^2, W_16^3)
  // Position 8-11 gets W_16^2, W_16^4=(-i), W_16^6
  // Position 12-15 gets W_16^3, W_16^6, W_16^9

  lines.push(`    ;; Stage 2 with twiddles`);

  // First group: 0,1,2,3 (no twiddles on input)
  lines.push(`    (local.set $t0 (f64x2.add (local.get $y0) (local.get $y2)))`);
  lines.push(`    (local.set $t1 (f64x2.sub (local.get $y0) (local.get $y2)))`);
  lines.push(`    (local.set $t2 (f64x2.add (local.get $y1) (local.get $y3)))`);
  lines.push(`    (local.set $t3 (f64x2.sub (local.get $y1) (local.get $y3)))`);
  lines.push(
    `    (local.set $t3 (f64x2.mul (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $t3) (local.get $t3)) (v128.const f64x2 1.0 -1.0)))`,
  );
  lines.push(
    `    (v128.store (i32.const ${baseOffset + 0}) (f64x2.add (local.get $t0) (local.get $t2)))`,
  );
  lines.push(
    `    (v128.store (i32.const ${baseOffset + 64}) (f64x2.add (local.get $t1) (local.get $t3)))`,
  );
  lines.push(
    `    (v128.store (i32.const ${baseOffset + 128}) (f64x2.sub (local.get $t0) (local.get $t2)))`,
  );
  lines.push(
    `    (v128.store (i32.const ${baseOffset + 192}) (f64x2.sub (local.get $t1) (local.get $t3)))`,
  );
  lines.push(``);

  // Second group: 4,5,6,7 with twiddles W_16^1, W_16^2, W_16^3
  // W_16^1 = (0.9238795325112867, -0.3826834323650898)
  // W_16^2 = (0.7071067811865476, -0.7071067811865476)
  // W_16^3 = (0.3826834323650898, -0.9238795325112867)
  const w16_1 = twiddle(16, 1);
  const w16_2 = twiddle(16, 2);
  const w16_3 = twiddle(16, 3);

  lines.push(`    (local.set $tmp (local.get $y5))`);
  lines.push(
    `    (local.set $y5 (f64x2.add (f64x2.mul (local.get $tmp) (v128.const f64x2 ${fmt(w16_1.re)} ${fmt(w16_1.re)})) (f64x2.mul (f64x2.mul (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $tmp) (local.get $tmp)) (v128.const f64x2 ${fmt(w16_1.im)} ${fmt(w16_1.im)})) (v128.const f64x2 -1.0 1.0))))`,
  );
  lines.push(`    (local.set $tmp (local.get $y6))`);
  lines.push(
    `    (local.set $y6 (f64x2.add (f64x2.mul (local.get $tmp) (v128.const f64x2 ${fmt(w16_2.re)} ${fmt(w16_2.re)})) (f64x2.mul (f64x2.mul (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $tmp) (local.get $tmp)) (v128.const f64x2 ${fmt(w16_2.im)} ${fmt(w16_2.im)})) (v128.const f64x2 -1.0 1.0))))`,
  );
  lines.push(`    (local.set $tmp (local.get $y7))`);
  lines.push(
    `    (local.set $y7 (f64x2.add (f64x2.mul (local.get $tmp) (v128.const f64x2 ${fmt(w16_3.re)} ${fmt(w16_3.re)})) (f64x2.mul (f64x2.mul (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $tmp) (local.get $tmp)) (v128.const f64x2 ${fmt(w16_3.im)} ${fmt(w16_3.im)})) (v128.const f64x2 -1.0 1.0))))`,
  );

  lines.push(`    (local.set $t0 (f64x2.add (local.get $y4) (local.get $y6)))`);
  lines.push(`    (local.set $t1 (f64x2.sub (local.get $y4) (local.get $y6)))`);
  lines.push(`    (local.set $t2 (f64x2.add (local.get $y5) (local.get $y7)))`);
  lines.push(`    (local.set $t3 (f64x2.sub (local.get $y5) (local.get $y7)))`);
  lines.push(
    `    (local.set $t3 (f64x2.mul (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $t3) (local.get $t3)) (v128.const f64x2 1.0 -1.0)))`,
  );
  lines.push(
    `    (v128.store (i32.const ${baseOffset + 16}) (f64x2.add (local.get $t0) (local.get $t2)))`,
  );
  lines.push(
    `    (v128.store (i32.const ${baseOffset + 80}) (f64x2.add (local.get $t1) (local.get $t3)))`,
  );
  lines.push(
    `    (v128.store (i32.const ${baseOffset + 144}) (f64x2.sub (local.get $t0) (local.get $t2)))`,
  );
  lines.push(
    `    (v128.store (i32.const ${baseOffset + 208}) (f64x2.sub (local.get $t1) (local.get $t3)))`,
  );
  lines.push(``);

  // Third group: 8,9,10,11 with twiddles W_16^2, W_16^4=-i, W_16^6
  // W_16^4 = (0, -1) = -i, special case
  // W_16^6 = (-0.7071067811865476, -0.7071067811865476)
  const w16_6 = twiddle(16, 6);

  lines.push(`    (local.set $tmp (local.get $y9))`);
  lines.push(
    `    (local.set $y9 (f64x2.add (f64x2.mul (local.get $tmp) (v128.const f64x2 ${fmt(w16_2.re)} ${fmt(w16_2.re)})) (f64x2.mul (f64x2.mul (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $tmp) (local.get $tmp)) (v128.const f64x2 ${fmt(w16_2.im)} ${fmt(w16_2.im)})) (v128.const f64x2 -1.0 1.0))))`,
  );
  lines.push(
    `    (local.set $y10 (f64x2.mul (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $y10) (local.get $y10)) (v128.const f64x2 1.0 -1.0)))`,
  );
  lines.push(`    (local.set $tmp (local.get $y11))`);
  lines.push(
    `    (local.set $y11 (f64x2.add (f64x2.mul (local.get $tmp) (v128.const f64x2 ${fmt(w16_6.re)} ${fmt(w16_6.re)})) (f64x2.mul (f64x2.mul (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $tmp) (local.get $tmp)) (v128.const f64x2 ${fmt(w16_6.im)} ${fmt(w16_6.im)})) (v128.const f64x2 -1.0 1.0))))`,
  );

  lines.push(`    (local.set $t0 (f64x2.add (local.get $y8) (local.get $y10)))`);
  lines.push(`    (local.set $t1 (f64x2.sub (local.get $y8) (local.get $y10)))`);
  lines.push(`    (local.set $t2 (f64x2.add (local.get $y9) (local.get $y11)))`);
  lines.push(`    (local.set $t3 (f64x2.sub (local.get $y9) (local.get $y11)))`);
  lines.push(
    `    (local.set $t3 (f64x2.mul (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $t3) (local.get $t3)) (v128.const f64x2 1.0 -1.0)))`,
  );
  lines.push(
    `    (v128.store (i32.const ${baseOffset + 32}) (f64x2.add (local.get $t0) (local.get $t2)))`,
  );
  lines.push(
    `    (v128.store (i32.const ${baseOffset + 96}) (f64x2.add (local.get $t1) (local.get $t3)))`,
  );
  lines.push(
    `    (v128.store (i32.const ${baseOffset + 160}) (f64x2.sub (local.get $t0) (local.get $t2)))`,
  );
  lines.push(
    `    (v128.store (i32.const ${baseOffset + 224}) (f64x2.sub (local.get $t1) (local.get $t3)))`,
  );
  lines.push(``);

  // Fourth group: 12,13,14,15 with twiddles W_16^3, W_16^6, W_16^9
  // W_16^9 = (-0.9238795325112867, 0.3826834323650898)
  const w16_9 = twiddle(16, 9);

  lines.push(`    (local.set $tmp (local.get $y13))`);
  lines.push(
    `    (local.set $y13 (f64x2.add (f64x2.mul (local.get $tmp) (v128.const f64x2 ${fmt(w16_3.re)} ${fmt(w16_3.re)})) (f64x2.mul (f64x2.mul (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $tmp) (local.get $tmp)) (v128.const f64x2 ${fmt(w16_3.im)} ${fmt(w16_3.im)})) (v128.const f64x2 -1.0 1.0))))`,
  );
  lines.push(`    (local.set $tmp (local.get $y14))`);
  lines.push(
    `    (local.set $y14 (f64x2.add (f64x2.mul (local.get $tmp) (v128.const f64x2 ${fmt(w16_6.re)} ${fmt(w16_6.re)})) (f64x2.mul (f64x2.mul (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $tmp) (local.get $tmp)) (v128.const f64x2 ${fmt(w16_6.im)} ${fmt(w16_6.im)})) (v128.const f64x2 -1.0 1.0))))`,
  );
  lines.push(`    (local.set $tmp (local.get $y15))`);
  lines.push(
    `    (local.set $y15 (f64x2.add (f64x2.mul (local.get $tmp) (v128.const f64x2 ${fmt(w16_9.re)} ${fmt(w16_9.re)})) (f64x2.mul (f64x2.mul (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $tmp) (local.get $tmp)) (v128.const f64x2 ${fmt(w16_9.im)} ${fmt(w16_9.im)})) (v128.const f64x2 -1.0 1.0))))`,
  );

  lines.push(`    (local.set $t0 (f64x2.add (local.get $y12) (local.get $y14)))`);
  lines.push(`    (local.set $t1 (f64x2.sub (local.get $y12) (local.get $y14)))`);
  lines.push(`    (local.set $t2 (f64x2.add (local.get $y13) (local.get $y15)))`);
  lines.push(`    (local.set $t3 (f64x2.sub (local.get $y13) (local.get $y15)))`);
  lines.push(
    `    (local.set $t3 (f64x2.mul (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $t3) (local.get $t3)) (v128.const f64x2 1.0 -1.0)))`,
  );
  lines.push(
    `    (v128.store (i32.const ${baseOffset + 48}) (f64x2.add (local.get $t0) (local.get $t2)))`,
  );
  lines.push(
    `    (v128.store (i32.const ${baseOffset + 112}) (f64x2.add (local.get $t1) (local.get $t3)))`,
  );
  lines.push(
    `    (v128.store (i32.const ${baseOffset + 176}) (f64x2.sub (local.get $t0) (local.get $t2)))`,
  );
  lines.push(
    `    (v128.store (i32.const ${baseOffset + 240}) (f64x2.sub (local.get $t1) (local.get $t3)))`,
  );

  return lines.join("\n");
}

// Generate full fused FFT-64
function generateFusedFFT64() {
  const lines = [];

  lines.push(`  ;; ============================================================================`);
  lines.push(`  ;; Fully Fused N=64 FFT: All stages inlined, no function calls`);
  lines.push(`  ;; Generated by scripts/generate_fused_fft64.js`);
  lines.push(`  ;; ============================================================================`);
  lines.push(`  (func $fft_64_fused`);
  lines.push(`    (local $a v128) (local $b v128) (local $t v128)`);
  lines.push(`    (local $t0 v128) (local $t1 v128) (local $t2 v128) (local $t3 v128)`);
  lines.push(`    (local $tmp v128)`);
  // Locals for FFT-16 (reused for each of the 4 FFT-16 blocks)
  for (let i = 0; i < 16; i++) {
    lines.push(`    (local $y${i} v128)`);
  }
  lines.push(``);

  // Stage 1: 32 butterflies with W_64^k twiddles
  lines.push(`    ;; ============================================================================`);
  lines.push(`    ;; Stage 1: 32 DIF butterflies with W_64^k twiddles`);
  lines.push(`    ;; ============================================================================`);
  for (let k = 0; k < 32; k++) {
    const offsetA = k * 16; // First half: 0, 16, 32, ..., 496
    const offsetB = offsetA + 512; // Second half: 512, 528, ..., 1008
    lines.push(generateButterfly(k, 64, offsetA, offsetB));
    lines.push(``);
  }

  // Stage 2a: 16 butterflies with W_32^k at offset 0 (first half)
  lines.push(`    ;; ============================================================================`);
  lines.push(`    ;; Stage 2a: 16 DIF butterflies with W_32^k at offset 0`);
  lines.push(`    ;; ============================================================================`);
  for (let k = 0; k < 16; k++) {
    const offsetA = k * 16; // 0, 16, 32, ..., 240
    const offsetB = offsetA + 256; // 256, 272, ..., 496
    lines.push(generateButterfly(k, 32, offsetA, offsetB));
    lines.push(``);
  }

  // Stage 2b: 16 butterflies with W_32^k at offset 512 (second half)
  lines.push(`    ;; ============================================================================`);
  lines.push(`    ;; Stage 2b: 16 DIF butterflies with W_32^k at offset 512`);
  lines.push(`    ;; ============================================================================`);
  for (let k = 0; k < 16; k++) {
    const offsetA = 512 + k * 16; // 512, 528, ..., 752
    const offsetB = offsetA + 256; // 768, 784, ..., 1008
    lines.push(generateButterfly(k, 32, offsetA, offsetB));
    lines.push(``);
  }

  // Stage 3: Four FFT-16 blocks at offsets 0, 256, 512, 768
  lines.push(`    ;; ============================================================================`);
  lines.push(`    ;; Stage 3: Four inlined FFT-16 blocks`);
  lines.push(`    ;; ============================================================================`);

  lines.push(generateFFT16(0));
  lines.push(``);
  lines.push(generateFFT16(256));
  lines.push(``);
  lines.push(generateFFT16(512));
  lines.push(``);
  lines.push(generateFFT16(768));

  lines.push(`  )`);

  return lines.join("\n");
}

// Output
console.log(generateFusedFFT64());
