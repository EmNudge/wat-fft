// Generate $fft_512_at and $fft_1024 code for fft_real_combined.wat

// W_N^k = cos(-2πk/N) + i*sin(-2πk/N) = cos(2πk/N) - i*sin(2πk/N)
function twiddle(k, n) {
  const angle = (2 * Math.PI * k) / n;
  return { re: Math.cos(angle), im: -Math.sin(angle) };
}

// Generate $fft_512_at (parameterized version of $fft_512)
function genFft512At() {
  const lines = [];
  lines.push("  ;; ============================================================================");
  lines.push("  ;; Parameterized N=512 FFT: DIF decomposition using two FFT-256 calls");
  lines.push("  ;; ============================================================================");
  lines.push("  (func $fft_512_at (param $base i32)");
  lines.push("    (local $a v128) (local $b v128) (local $t v128)");
  lines.push("");

  const n = 512;
  const half = n / 2; // 256
  const halfBytes = half * 16; // 4096

  for (let k = 0; k < half; k++) {
    const w = twiddle(k, n);
    const offset1 = k * 16;
    const offset2 = offset1 + halfBytes;

    if (k === 0) {
      lines.push(`    ;; k=0: W_512^0 = (1, 0)`);
      lines.push(
        `    (local.set $a (v128.load (i32.add (local.get $base) (i32.const ${offset1}))))`,
      );
      lines.push(
        `    (local.set $b (v128.load (i32.add (local.get $base) (i32.const ${offset2}))))`,
      );
      lines.push(
        `    (v128.store (i32.add (local.get $base) (i32.const ${offset1})) (f64x2.add (local.get $a) (local.get $b)))`,
      );
      lines.push(
        `    (v128.store (i32.add (local.get $base) (i32.const ${offset2})) (f64x2.sub (local.get $a) (local.get $b)))`,
      );
    } else if (k === 128) {
      lines.push(`    ;; k=128: W_512^128 = (0, -1) - multiply by -i`);
      lines.push(
        `    (local.set $a (v128.load (i32.add (local.get $base) (i32.const ${offset1}))))`,
      );
      lines.push(
        `    (local.set $b (v128.load (i32.add (local.get $base) (i32.const ${offset2}))))`,
      );
      lines.push(`    (local.set $t (f64x2.sub (local.get $a) (local.get $b)))`);
      lines.push(
        `    (v128.store (i32.add (local.get $base) (i32.const ${offset1})) (f64x2.add (local.get $a) (local.get $b)))`,
      );
      lines.push(
        `    (v128.store (i32.add (local.get $base) (i32.const ${offset2})) (f64x2.mul (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $t) (local.get $t)) (v128.const f64x2 1.0 -1.0)))`,
      );
    } else {
      lines.push(`    ;; k=${k}`);
      lines.push(
        `    (local.set $a (v128.load (i32.add (local.get $base) (i32.const ${offset1}))))`,
      );
      lines.push(
        `    (local.set $b (v128.load (i32.add (local.get $base) (i32.const ${offset2}))))`,
      );
      lines.push(`    (local.set $t (f64x2.sub (local.get $a) (local.get $b)))`);
      lines.push(
        `    (v128.store (i32.add (local.get $base) (i32.const ${offset1})) (f64x2.add (local.get $a) (local.get $b)))`,
      );
      lines.push(`    (v128.store (i32.add (local.get $base) (i32.const ${offset2})) (f64x2.add`);
      lines.push(`      (f64x2.mul (local.get $t) (v128.const f64x2 ${w.re} ${w.re}))`);
      lines.push(
        `      (f64x2.mul (f64x2.mul (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $t) (local.get $t)) (v128.const f64x2 ${w.im} ${w.im})) (v128.const f64x2 -1.0 1.0))))`,
      );
    }
    lines.push("");
  }

  lines.push("    ;; Run FFT-256 on each half");
  lines.push("    (call $fft_256_at (local.get $base))");
  lines.push(`    (call $fft_256_at (i32.add (local.get $base) (i32.const ${halfBytes})))`);
  lines.push("  )");

  return lines.join("\n");
}

// Generate $fft_1024
function genFft1024() {
  const lines = [];
  lines.push("  ;; ============================================================================");
  lines.push("  ;; Hierarchical N=1024 FFT: DIF decomposition using two FFT-512 calls");
  lines.push("  ;; ============================================================================");
  lines.push("  (func $fft_1024");
  lines.push("    (local $a v128) (local $b v128) (local $t v128)");
  lines.push("    ;; W_1024^k twiddles for k=0..511");
  lines.push("");

  const n = 1024;
  const half = n / 2; // 512
  const halfBytes = half * 16; // 8192

  for (let k = 0; k < half; k++) {
    const w = twiddle(k, n);
    const offset1 = k * 16;
    const offset2 = offset1 + halfBytes;

    if (k === 0) {
      lines.push(`    ;; k=0: W_1024^0 = (1, 0)`);
      lines.push(`    (local.set $a (v128.load (i32.const ${offset1})))`);
      lines.push(`    (local.set $b (v128.load (i32.const ${offset2})))`);
      lines.push(
        `    (v128.store (i32.const ${offset1}) (f64x2.add (local.get $a) (local.get $b)))`,
      );
      lines.push(
        `    (v128.store (i32.const ${offset2}) (f64x2.sub (local.get $a) (local.get $b)))`,
      );
    } else if (k === 256) {
      lines.push(`    ;; k=256: W_1024^256 = (0, -1) - multiply by -i`);
      lines.push(`    (local.set $a (v128.load (i32.const ${offset1})))`);
      lines.push(`    (local.set $b (v128.load (i32.const ${offset2})))`);
      lines.push(`    (local.set $t (f64x2.sub (local.get $a) (local.get $b)))`);
      lines.push(
        `    (v128.store (i32.const ${offset1}) (f64x2.add (local.get $a) (local.get $b)))`,
      );
      lines.push(
        `    (v128.store (i32.const ${offset2}) (f64x2.mul (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $t) (local.get $t)) (v128.const f64x2 1.0 -1.0)))`,
      );
    } else {
      lines.push(`    ;; k=${k}`);
      lines.push(`    (local.set $a (v128.load (i32.const ${offset1})))`);
      lines.push(`    (local.set $b (v128.load (i32.const ${offset2})))`);
      lines.push(`    (local.set $t (f64x2.sub (local.get $a) (local.get $b)))`);
      lines.push(
        `    (v128.store (i32.const ${offset1}) (f64x2.add (local.get $a) (local.get $b)))`,
      );
      lines.push(`    (v128.store (i32.const ${offset2}) (f64x2.add`);
      lines.push(`      (f64x2.mul (local.get $t) (v128.const f64x2 ${w.re} ${w.re}))`);
      lines.push(
        `      (f64x2.mul (f64x2.mul (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $t) (local.get $t)) (v128.const f64x2 ${w.im} ${w.im})) (v128.const f64x2 -1.0 1.0))))`,
      );
    }
    lines.push("");
  }

  lines.push("    ;; Run FFT-512 on each half");
  lines.push("    (call $fft_512_at (i32.const 0))");
  lines.push(`    (call $fft_512_at (i32.const ${halfBytes}))`);
  lines.push("  )");

  return lines.join("\n");
}

console.log(genFft512At());
console.log("\n");
console.log(genFft1024());
