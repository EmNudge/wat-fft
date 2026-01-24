#!/usr/bin/env node
/**
 * Generate a fully fused FFT-64 codelet with FMA instructions
 *
 * Uses f64x2.relaxed_madd for fused multiply-add operations
 */

// Twiddle factor: W_N^k = cos(-2πk/N) + i*sin(-2πk/N)
function twiddle(N, k) {
  const angle = (-2 * Math.PI * k) / N;
  return {
    re: Math.cos(angle),
    im: Math.sin(angle),
  };
}

function fmt(x) {
  if (x === 0) return "0.0";
  if (x === 1) return "1.0";
  if (x === -1) return "-1.0";
  return x.toPrecision(17);
}

// Generate butterfly with FMA twiddle multiplication
function generateButterfly(k, N, offsetA, offsetB) {
  const w = twiddle(N, k);
  const lines = [];

  lines.push(`    ;; k=${k}: W_${N}^${k} = (${fmt(w.re)}, ${fmt(w.im)})`);
  lines.push(`    (local.set $a (v128.load (i32.const ${offsetA})))`);
  lines.push(`    (local.set $b (v128.load (i32.const ${offsetB})))`);

  if (k === 0) {
    lines.push(`    (v128.store (i32.const ${offsetA}) (f64x2.add (local.get $a) (local.get $b)))`);
    lines.push(`    (v128.store (i32.const ${offsetB}) (f64x2.sub (local.get $a) (local.get $b)))`);
  } else if (w.re === 0 && Math.abs(w.im + 1) < 1e-10) {
    // W = -i, special case
    lines.push(`    (local.set $t (f64x2.sub (local.get $a) (local.get $b)))`);
    lines.push(`    (v128.store (i32.const ${offsetA}) (f64x2.add (local.get $a) (local.get $b)))`);
    lines.push(
      `    (v128.store (i32.const ${offsetB}) (f64x2.mul (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $t) (local.get $t)) (v128.const f64x2 1.0 -1.0)))`,
    );
  } else {
    // FMA version: result = relaxed_madd(t, re_vec, shuffle(t)*im*sign)
    lines.push(`    (local.set $t (f64x2.sub (local.get $a) (local.get $b)))`);
    lines.push(`    (v128.store (i32.const ${offsetA}) (f64x2.add (local.get $a) (local.get $b)))`);
    lines.push(`    (v128.store (i32.const ${offsetB}) (f64x2.relaxed_madd`);
    lines.push(`      (local.get $t) (v128.const f64x2 ${fmt(w.re)} ${fmt(w.re)})`);
    lines.push(
      `      (f64x2.mul (f64x2.mul (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $t) (local.get $t)) (v128.const f64x2 ${fmt(w.im)} ${fmt(w.im)})) (v128.const f64x2 -1.0 1.0))))`,
    );
  }

  return lines.join("\n");
}

// Generate fft_16 code for a specific base offset with FMA
function generateFFT16(baseOffset) {
  const lines = [];

  lines.push(`    ;; ========== FFT-16 at offset ${baseOffset} ==========`);

  for (let i = 0; i < 16; i++) {
    lines.push(`    (local.set $y${i} (v128.load (i32.const ${baseOffset + i * 16})))`);
  }

  // Stage 1: Four radix-4 butterflies
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

  // Stage 2 with twiddles (using FMA)
  lines.push(`    ;; Stage 2 with twiddles (FMA)`);

  // First group: 0,1,2,3 (no twiddles)
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

  // Helper for FMA twiddle multiply
  const fmaTwiddle = (varName, w) => {
    return [
      `    (local.set $tmp (local.get $${varName}))`,
      `    (local.set $${varName} (f64x2.relaxed_madd (local.get $tmp) (v128.const f64x2 ${fmt(w.re)} ${fmt(w.re)}) (f64x2.mul (f64x2.mul (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $tmp) (local.get $tmp)) (v128.const f64x2 ${fmt(w.im)} ${fmt(w.im)})) (v128.const f64x2 -1.0 1.0))))`,
    ].join("\n");
  };

  const w16_1 = twiddle(16, 1);
  const w16_2 = twiddle(16, 2);
  const w16_3 = twiddle(16, 3);
  const w16_6 = twiddle(16, 6);
  const w16_9 = twiddle(16, 9);

  // Second group: 4,5,6,7
  lines.push(fmaTwiddle("y5", w16_1));
  lines.push(fmaTwiddle("y6", w16_2));
  lines.push(fmaTwiddle("y7", w16_3));

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

  // Third group: 8,9,10,11
  lines.push(fmaTwiddle("y9", w16_2));
  lines.push(
    `    (local.set $y10 (f64x2.mul (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $y10) (local.get $y10)) (v128.const f64x2 1.0 -1.0)))`,
  );
  lines.push(fmaTwiddle("y11", w16_6));

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

  // Fourth group: 12,13,14,15
  lines.push(fmaTwiddle("y13", w16_3));
  lines.push(fmaTwiddle("y14", w16_6));
  lines.push(fmaTwiddle("y15", w16_9));

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

function generateFusedFFT64FMA() {
  const lines = [];

  lines.push(`  ;; ============================================================================`);
  lines.push(`  ;; Fully Fused N=64 FFT with FMA: All stages inlined, no function calls`);
  lines.push(`  ;; Generated by scripts/generate_fused_fft64_fma.js`);
  lines.push(`  ;; ============================================================================`);
  lines.push(`  (func $fft_64_fused`);
  lines.push(`    (local $a v128) (local $b v128) (local $t v128)`);
  lines.push(`    (local $t0 v128) (local $t1 v128) (local $t2 v128) (local $t3 v128)`);
  lines.push(`    (local $tmp v128)`);
  for (let i = 0; i < 16; i++) {
    lines.push(`    (local $y${i} v128)`);
  }
  lines.push(``);

  // Stage 1
  lines.push(`    ;; ============================================================================`);
  lines.push(`    ;; Stage 1: 32 DIF butterflies with W_64^k twiddles`);
  lines.push(`    ;; ============================================================================`);
  for (let k = 0; k < 32; k++) {
    lines.push(generateButterfly(k, 64, k * 16, k * 16 + 512));
    lines.push(``);
  }

  // Stage 2a
  lines.push(`    ;; ============================================================================`);
  lines.push(`    ;; Stage 2a: 16 DIF butterflies with W_32^k at offset 0`);
  lines.push(`    ;; ============================================================================`);
  for (let k = 0; k < 16; k++) {
    lines.push(generateButterfly(k, 32, k * 16, k * 16 + 256));
    lines.push(``);
  }

  // Stage 2b
  lines.push(`    ;; ============================================================================`);
  lines.push(`    ;; Stage 2b: 16 DIF butterflies with W_32^k at offset 512`);
  lines.push(`    ;; ============================================================================`);
  for (let k = 0; k < 16; k++) {
    lines.push(generateButterfly(k, 32, 512 + k * 16, 512 + k * 16 + 256));
    lines.push(``);
  }

  // Stage 3
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

console.log(generateFusedFFT64FMA());
