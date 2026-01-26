import { execSync } from "child_process";
import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const modulesDir = path.join(__dirname, "modules");
const distDir = path.join(__dirname, "dist");

if (!fs.existsSync(distDir)) fs.mkdirSync(distDir, { recursive: true });

function run(cmd) {
  try {
    execSync(cmd, { stdio: "pipe", cwd: __dirname });
    return true;
  } catch (error) {
    console.error(`  Error: ${error.stderr?.toString() || error.message}`);
    return false;
  }
}

// Main outputs - self-contained modules
const outputs = [
  { name: "fft_combined", desc: "Complex FFT (f64)" },
  { name: "fft_real_combined", desc: "Real FFT (f64)" },
  { name: "fft_stockham_f32_dual", desc: "Complex FFT (f32)" },
  { name: "fft_real_f32_dual", desc: "Real FFT (f32)" },
];

console.log("Building FFT modules...\n");

outputs.forEach(({ name, desc }) => {
  const srcPath = path.join(modulesDir, `${name}.wat`);
  const outputWasm = path.join(distDir, `${name}.wasm`);

  if (run(`wasm-tools parse ${srcPath} -o ${outputWasm}`)) {
    console.log(`  ${name}.wasm - ${desc}`);
  }
});

console.log("\nBuild complete!");
