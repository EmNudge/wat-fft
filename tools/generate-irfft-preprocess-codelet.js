// Generates unrolled $irfft_preprocess_64 / $irfft_preprocess_128 WAT codelets
// (Experiments 51-52). Mirrors $rfft_postprocess_64/128 structure, with the
// inverse formula, emitting Z scaled by 1/n2 (native inverse path):
//   Z[k]/n2    = h*(X[k] + conj(X[n2-k]) + conj(W_rot_k)*(X[k] - conj(X[n2-k])))
//   Z[n2-k]/n2 = h*(X[n2-k] + conj(X[k]) + W_rot_k*(X[n2-k] - conj(X[k])))
// where h = 0.5/n2 folds the inverse FFT's 1/n2 scale into the formula's 0.5,
// W[k] = exp(-i*pi*k/n2), W_rot = (W.im, -W.re), conj(W_rot) = (W.im, W.re).
// The middle element is Z[mid]/n2 = conj(X[mid])/n2.

const f = Math.fround;

// cwrot lane pair for k: (W.im, W.re) = (-sin(pi*k/n2), cos(pi*k/n2)) as f32
function cwrotLanes(k, n2) {
  const t = (Math.PI * k) / n2;
  return [f(-Math.sin(t)), f(Math.cos(t))];
}

const SHUF_SWAP_PAIRS = "8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7";
const SHUF_RE_DUAL = "0 1 2 3 0 1 2 3 8 9 10 11 8 9 10 11";
const SHUF_IM_DUAL = "4 5 6 7 4 5 6 7 12 13 14 15 12 13 14 15";
const SHUF_SWAPREIM_DUAL = "4 5 6 7 0 1 2 3 12 13 14 15 8 9 10 11";
const SHUF_RE_SINGLE = "0 1 2 3 0 1 2 3 0 1 2 3 0 1 2 3";
const SHUF_IM_SINGLE = "4 5 6 7 4 5 6 7 4 5 6 7 4 5 6 7";
const SHUF_SWAPREIM_SINGLE = "4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3";

function cmul(dst, src, wRe, wIm, wSwap) {
  return `    (local.set $wr (i8x16.shuffle ${wRe} (local.get $${src}) (local.get $${src})))
    (local.set $wi (i8x16.shuffle ${wIm} (local.get $${src}) (local.get $${src})))
    (local.set $prod (f32x4.mul (local.get $${dst}) (local.get $wr)))
    (local.set $swapped (i8x16.shuffle ${wSwap} (local.get $${dst}) (local.get $${dst})))`;
}

function dualPair(k, n2, dstBase) {
  const addrK = 8 * k;
  const addrN2k = 8 * (n2 - k - 1);
  const [s0, c0] = cwrotLanes(k, n2);
  const [s1, c1] = cwrotLanes(k + 1, n2);
  return `    ;; ======== Pairs k=${k},${k + 1} and k=${n2 - k},${n2 - k - 1} ========
    (local.set $xk (v128.load (i32.const ${addrK})))
    (local.set $xn2k (v128.load (i32.const ${addrN2k})))
    (local.set $xn2k (i8x16.shuffle ${SHUF_SWAP_PAIRS} (local.get $xn2k) (local.get $xn2k)))
    (local.set $conj_xn2k (v128.xor (local.get $xn2k) (global.get $CONJ_MASK_F32)))
    (local.set $sum (f32x4.add (local.get $xk) (local.get $conj_xn2k)))
    (local.set $diff (f32x4.sub (local.get $xk) (local.get $conj_xn2k)))
    ;; conj(W_rot) for k=${k},${k + 1}: [(W.im, W.re), ...]
    (local.set $cwrot (v128.const f32x4 ${s0} ${c0} ${s1} ${c1}))
${cmul("diff", "cwrot", SHUF_RE_DUAL, SHUF_IM_DUAL, SHUF_SWAPREIM_DUAL)}
    (local.set $wd (f32x4.add (local.get $prod) (f32x4.mul (f32x4.mul (local.get $swapped) (local.get $wi)) (global.get $SIGN_MASK))))
    (local.set $zk (f32x4.mul (f32x4.add (local.get $sum) (local.get $wd)) (local.get $half)))
    ;; Z[${n2 - k},${n2 - k - 1}] side: W_rot = conj(cwrot)
    (local.set $conj_xk (v128.xor (local.get $xk) (global.get $CONJ_MASK_F32)))
    (local.set $sum2 (f32x4.add (local.get $xn2k) (local.get $conj_xk)))
    (local.set $diff2 (f32x4.sub (local.get $xn2k) (local.get $conj_xk)))
    (local.set $wrot (v128.xor (local.get $cwrot) (global.get $CONJ_MASK_F32)))
${cmul("diff2", "wrot", SHUF_RE_DUAL, SHUF_IM_DUAL, SHUF_SWAPREIM_DUAL)}
    (local.set $wd2 (f32x4.add (local.get $prod) (f32x4.mul (f32x4.mul (local.get $swapped) (local.get $wi)) (global.get $SIGN_MASK))))
    (local.set $zn2k (f32x4.mul (f32x4.add (local.get $sum2) (local.get $wd2)) (local.get $half)))
    (v128.store (i32.const ${dstBase + addrK}) (local.get $zk))
    (local.set $zn2k (i8x16.shuffle ${SHUF_SWAP_PAIRS} (local.get $zn2k) (local.get $zn2k)))
    (v128.store (i32.const ${dstBase + addrN2k}) (local.get $zn2k))
`;
}

function singlePair(k, n2, dstBase) {
  const addrK = 8 * k;
  const addrN2k = 8 * (n2 - k);
  const [s0, c0] = cwrotLanes(k, n2);
  return `    ;; ======== Remaining pair k=${k} and k=${n2 - k} (64-bit lanes) ========
    (local.set $xk (v128.load64_zero (i32.const ${addrK})))
    (local.set $xn2k (v128.load64_zero (i32.const ${addrN2k})))
    (local.set $conj_xn2k (v128.xor (local.get $xn2k) (global.get $CONJ_MASK_F32)))
    (local.set $sum (f32x4.add (local.get $xk) (local.get $conj_xn2k)))
    (local.set $diff (f32x4.sub (local.get $xk) (local.get $conj_xn2k)))
    (local.set $cwrot (v128.const f32x4 ${s0} ${c0} ${s0} ${c0}))
${cmul("diff", "cwrot", SHUF_RE_SINGLE, SHUF_IM_SINGLE, SHUF_SWAPREIM_SINGLE)}
    (local.set $wd (f32x4.add (local.get $prod) (f32x4.mul (f32x4.mul (local.get $swapped) (local.get $wi)) (global.get $SIGN_MASK))))
    (local.set $zk (f32x4.mul (f32x4.add (local.get $sum) (local.get $wd)) (local.get $half)))
    (local.set $conj_xk (v128.xor (local.get $xk) (global.get $CONJ_MASK_F32)))
    (local.set $sum2 (f32x4.add (local.get $xn2k) (local.get $conj_xk)))
    (local.set $diff2 (f32x4.sub (local.get $xn2k) (local.get $conj_xk)))
    (local.set $wrot (v128.xor (local.get $cwrot) (global.get $CONJ_MASK_F32)))
${cmul("diff2", "wrot", SHUF_RE_SINGLE, SHUF_IM_SINGLE, SHUF_SWAPREIM_SINGLE)}
    (local.set $wd2 (f32x4.add (local.get $prod) (f32x4.mul (f32x4.mul (local.get $swapped) (local.get $wi)) (global.get $SIGN_MASK))))
    (local.set $zn2k (f32x4.mul (f32x4.add (local.get $sum2) (local.get $wd2)) (local.get $half)))
    (v128.store64_lane 0 (i32.const ${dstBase + addrK}) (local.get $zk))
    (v128.store64_lane 0 (i32.const ${dstBase + addrN2k}) (local.get $zn2k))
`;
}

function genCodelet(n) {
  const n2 = n / 2;
  const kEnd = n2 / 2;
  const h = 0.5 / n2; // exact in binary floating point (n2 a power of 2)
  const inv = 1 / n2;
  // n=64 (n2=32): the inverse Stockham has an odd stage count, so the
  // preprocess writes Z to SECONDARY (65536) and the FFT lands at offset 0.
  // n=128 (n2=64): even stage count, Z stays at offset 0.
  const dstBase = Math.log2(n2) % 2 === 1 ? 65536 : 0;
  let body = `  (func $irfft_preprocess_${n}
    (local $xk v128) (local $xn2k v128) (local $conj_xn2k v128) (local $conj_xk v128)
    (local $cwrot v128) (local $wrot v128)
    (local $sum v128) (local $diff v128) (local $wd v128)
    (local $sum2 v128) (local $diff2 v128) (local $wd2 v128)
    (local $zk v128) (local $zn2k v128) (local $half v128)
    (local $wr v128) (local $wi v128) (local $prod v128) (local $swapped v128)
    (local $x0_re f32) (local $xn2_re f32)

    ;; h = 0.5/n2 = ${h}: folds the inverse FFT's 1/n2 scale into the 0.5
    (local.set $half (v128.const f32x4 ${h} ${h} ${h} ${h}))

    ;; DC (scaled output): Z[0]/n2 = ((X0+Xn2)*h, (X0-Xn2)*h)
    (local.set $x0_re (f32.load (i32.const 0)))
    (local.set $xn2_re (f32.load (i32.const ${8 * n2})))
    (f32.store (i32.const ${dstBase}) (f32.mul (f32.const ${h}) (f32.add (local.get $x0_re) (local.get $xn2_re))))
    (f32.store (i32.const ${dstBase + 4}) (f32.mul (f32.const ${h}) (f32.sub (local.get $x0_re) (local.get $xn2_re))))

`;
  let k = 1;
  for (; k + 1 < kEnd; k += 2) body += dualPair(k, n2, dstBase) + "\n";
  if (k < kEnd) body += singlePair(k, n2, dstBase) + "\n";
  body += `    ;; Middle element (k=${kEnd}): Z[mid]/n2 = conj(X[mid]) * ${inv}
    (local.set $xk (v128.load64_zero (i32.const ${8 * kEnd})))
    (local.set $xk (f32x4.mul (v128.xor (local.get $xk) (global.get $CONJ_MASK_F32)) (v128.const f32x4 ${inv} ${inv} ${inv} ${inv})))
    (v128.store64_lane 0 (i32.const ${dstBase + 8 * kEnd}) (local.get $xk))
  )`;
  return body;
}

console.log(genCodelet(64));
console.log();
console.log(genCodelet(128));
