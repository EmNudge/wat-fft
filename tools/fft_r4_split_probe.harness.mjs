// Experiment 58 probe harness: radix-4 split-format core vs existing cores vs pffft SIMD.
import { readFile } from "node:fs/promises";
import PFFFT_SIMD from "@echogarden/pffft-wasm/simd";

const DIR = new URL(".", import.meta.url).pathname;
const DIST = new URL("../dist", import.meta.url).pathname;

async function loadWasm(path) {
  const buf = await readFile(path);
  return (await WebAssembly.instantiate(await WebAssembly.compile(buf), {})).exports;
}

const probe = await loadWasm(`${DIR}/fft_r4_split_probe.wasm`);
const dual = await loadWasm(`${DIST}/fft_stockham_f32_dual.wasm`);
const split = await loadWasm(`${DIST}/fft_split_native_f32.wasm`);
const pffft = await PFFFT_SIMD();

const SRC_RE = 0,
  SRC_IM = 65536,
  DST_RE = 131072,
  DST_IM = 196608,
  TW = 262144;

function precomputeTwiddles(n) {
  const mem = new Float32Array(probe.memory.buffer);
  let off = TW / 4;
  for (let l = 1, s = n / 4; s >= 1; s >>= 2, l <<= 2) {
    for (let j = 0; j < l; j++) {
      const a1 = (-Math.PI * j) / (2 * l);
      mem[off + j] = Math.cos(a1);
      mem[off + l + j] = Math.sin(a1);
      mem[off + 2 * l + j] = Math.cos(2 * a1);
      mem[off + 3 * l + j] = Math.sin(2 * a1);
      mem[off + 4 * l + j] = Math.cos(3 * a1);
      mem[off + 5 * l + j] = Math.sin(3 * a1);
    }
    off += 6 * l;
  }
}

function dft(re, im) {
  const n = re.length;
  const or_ = new Float64Array(n),
    oi = new Float64Array(n);
  for (let k = 0; k < n; k++) {
    let sr = 0,
      si = 0;
    for (let t = 0; t < n; t++) {
      const ang = (-2 * Math.PI * k * t) / n;
      sr += re[t] * Math.cos(ang) - im[t] * Math.sin(ang);
      si += re[t] * Math.sin(ang) + im[t] * Math.cos(ang);
    }
    or_[k] = sr;
    oi[k] = si;
  }
  return { re: or_, im: oi };
}

// ---- correctness ----
console.log("=== Correctness (vs f64 reference DFT) ===");
for (const n of [16, 64, 256, 1024, 4096]) {
  const re = Float32Array.from({ length: n }, () => Math.random() * 2 - 1);
  const im = Float32Array.from({ length: n }, () => Math.random() * 2 - 1);
  precomputeTwiddles(n);
  new Float32Array(probe.memory.buffer, SRC_RE, n).set(re);
  new Float32Array(probe.memory.buffer, SRC_IM, n).set(im);
  const parity = probe.fft_r4(n);
  const outRe = new Float32Array(probe.memory.buffer, parity ? DST_RE : SRC_RE, n);
  const outIm = new Float32Array(probe.memory.buffer, parity ? DST_IM : SRC_IM, n);
  const want = dft(re, im);
  let maxErr = 0,
    scale = Math.sqrt(n);
  for (let i = 0; i < n; i++) {
    maxErr = Math.max(maxErr, Math.abs(outRe[i] - want.re[i]), Math.abs(outIm[i] - want.im[i]));
  }
  const rel = maxErr / scale;
  console.log(
    `N=${n}: max abs err = ${maxErr.toExponential(2)} (rel ~${rel.toExponential(1)}) ${rel < 1e-5 ? "OK" : "FAIL"}`,
  );
}

// ---- benchmark ----
const DURATION = 1500;
function bench(fn) {
  for (let i = 0; i < 300; i++) fn();
  const t0 = performance.now();
  let iters = 0;
  while (performance.now() - t0 < DURATION) {
    fn();
    iters++;
  }
  return (iters / (performance.now() - t0)) * 1000;
}

console.log("\n=== Throughput (input copy included for all) ===");
for (const n of [64, 256, 1024, 4096]) {
  const re = Float32Array.from({ length: n }, () => Math.random() * 2 - 1);
  const im = Float32Array.from({ length: n }, () => Math.random() * 2 - 1);
  const inter = new Float32Array(n * 2);
  for (let i = 0; i < n; i++) {
    inter[2 * i] = re[i];
    inter[2 * i + 1] = im[i];
  }

  // probe (radix-4 split)
  precomputeTwiddles(n);
  const pSrcRe = new Float32Array(probe.memory.buffer, SRC_RE, n);
  const pSrcIm = new Float32Array(probe.memory.buffer, SRC_IM, n);
  const rProbe = bench(() => {
    pSrcRe.set(re);
    pSrcIm.set(im);
    probe.fft_r4(n);
  });

  // existing split module (radix-2, multi-twiddle r1/r2)
  split.precompute_twiddles_split(n);
  const sRe = new Float32Array(split.memory.buffer, split.REAL_OFFSET.value, n);
  const sIm = new Float32Array(split.memory.buffer, split.IMAG_OFFSET.value, n);
  const rSplit = bench(() => {
    sRe.set(re);
    sIm.set(im);
    split.fft_split(n);
  });

  // interleaved dual module
  dual.precompute_twiddles(n);
  const dIn = new Float32Array(dual.memory.buffer, 0, n * 2);
  const rDual = bench(() => {
    dIn.set(inter);
    dual.fft(n);
  });

  // pffft SIMD
  const setup = pffft._pffft_new_setup(n, 1);
  const inPtr = pffft._pffft_aligned_malloc(n * 2 * 4);
  const outPtr = pffft._pffft_aligned_malloc(n * 2 * 4);
  const pfIn = () => new Float32Array(pffft.HEAPF32.buffer, inPtr, n * 2);
  const rPffft = bench(() => {
    pfIn().set(inter);
    pffft._pffft_transform_ordered(setup, inPtr, outPtr, 0, 0);
  });
  pffft._pffft_aligned_free(inPtr);
  pffft._pffft_aligned_free(outPtr);
  pffft._pffft_destroy_setup(setup);

  const f = (x) => Math.round(x).toLocaleString();
  console.log(
    `N=${n}: r4-split=${f(rProbe)}  old-split=${f(rSplit)}  dual=${f(rDual)}  pffft-simd=${f(rPffft)}  | r4/pffft=${(rProbe / rPffft).toFixed(2)}x r4/dual=${(rProbe / rDual).toFixed(2)}x`,
  );
}
