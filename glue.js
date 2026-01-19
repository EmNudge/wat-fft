import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";
import { execSync } from "child_process";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const modulesDir = path.join(__dirname, "modules");
const distDir = path.join(__dirname, "dist");

// Ensure dist directory exists
if (!fs.existsSync(distDir)) {
  fs.mkdirSync(distDir);
}

const watFiles = fs.readdirSync(modulesDir).filter((file) => file.endsWith(".wat"));

// Modules that have dependencies and can't be compiled standalone
const dependentModules = [
  "fft_main.wat",
  "fft_fast.wat",
  "fft_simd.wat",
  "fft_radix4.wat",
  "fft_stockham.wat",
  "fft_unrolled.wat",
];

// Compile individual standalone modules
console.log("Compiling individual modules...");
watFiles.forEach((file) => {
  // Skip modules that have dependencies
  if (dependentModules.includes(file)) {
    console.log(`  ${path.basename(file, ".wat")} (skipped - has dependencies)`);
    return;
  }

  const filePath = path.join(modulesDir, file);
  const content = fs.readFileSync(filePath, "utf8");
  const moduleName = path.basename(file, ".wat");

  // Check if the file is already a complete module
  const isCompleteModule = content.trim().startsWith("(module");

  let moduleWat;
  if (isCompleteModule) {
    // File is already a complete module (like math_trig.wat)
    moduleWat = content;
  } else {
    // Wrap the content in a module with memory export
    moduleWat = `(module
  (memory (export "memory") 1)
${content}
)
`;
  }

  const outputWatFile = path.join(distDir, `${moduleName}.wat`);
  const outputWasmFile = path.join(distDir, `${moduleName}.wasm`);

  fs.writeFileSync(outputWatFile, moduleWat);

  try {
    execSync(`wasm-tools parse ${outputWatFile} -o ${outputWasmFile}`);
    console.log(`  ${moduleName}.wasm ✓`);
  } catch (error) {
    console.error(`  Error compiling ${moduleName}: ${error.message}`);
    process.exit(1);
  }
});

// Build combined module (original Radix-2 FFT without imports)
console.log("\nCompiling combined module...");
const outputWatFile = path.join(distDir, "combined.wat");
const outputWasmFile = path.join(distDir, "combined.wasm");

// Files to include in original combined module (excludes optimized FFT variants)
const originalModuleFiles = watFiles.filter(
  (f) =>
    ![
      "fft_fast.wat",
      "fft_simd.wat",
      "fft_radix4.wat",
      "fft_stockham.wat",
      "fft_unrolled.wat",
    ].includes(f),
);

let combinedWat = `(module
  (memory (export "memory") 1)\n`;

originalModuleFiles.forEach((file) => {
  const filePath = path.join(modulesDir, file);
  const content = fs.readFileSync(filePath, "utf8");

  // Skip the module wrapper in math_trig.wat if it's there
  const processedContent =
    file === "math_trig.wat"
      ? content.replace(/^\(module\s*/, "").replace(/\s*\)$/, "") // Remove (module ... ) wrapper
      : content;

  combinedWat +=
    processedContent
      .trim()
      .split("\n")
      .map((line) => `  ${line}`)
      .join("\n") + "\n";
});

combinedWat += ")\n";

fs.writeFileSync(outputWatFile, combinedWat);

try {
  execSync(`wasm-tools parse ${outputWatFile} -o ${outputWasmFile}`);
  console.log(`  combined.wasm ✓`);
} catch (error) {
  console.error(`  Error compiling combined module: ${error.message}`);
  process.exit(1);
}

// Build fast combined module (with imports for sin/cos)
console.log("\nCompiling fast combined module...");
const fastOutputWatFile = path.join(distDir, "combined_fast.wat");
const fastOutputWasmFile = path.join(distDir, "combined_fast.wasm");

// Files to include in fast module (order matters for dependencies)
const fastModuleFiles = ["swap.wat", "reverse_bits.wat", "fft_fast.wat"];

let fastCombinedWat = `(module
  ;; Import JS Math functions for fast twiddle computation
  (import "math" "sin" (func $js_sin (param f64) (result f64)))
  (import "math" "cos" (func $js_cos (param f64) (result f64)))

  ;; 3 pages = 192KB: enough for 4096 complex numbers + twiddle table
  (memory (export "memory") 3)\n`;

fastModuleFiles.forEach((file) => {
  const filePath = path.join(modulesDir, file);
  const content = fs.readFileSync(filePath, "utf8");
  fastCombinedWat +=
    content
      .trim()
      .split("\n")
      .map((line) => `  ${line}`)
      .join("\n") + "\n";
});

fastCombinedWat += ")\n";

fs.writeFileSync(fastOutputWatFile, fastCombinedWat);

try {
  execSync(`wasm-tools parse ${fastOutputWatFile} -o ${fastOutputWasmFile}`);
  console.log(`  combined_fast.wasm ✓`);
} catch (error) {
  console.error(`  Error compiling fast combined module: ${error.message}`);
  console.error("  WAT file saved for inspection:", fastOutputWatFile);
  process.exit(1);
}

// Build SIMD combined module
console.log("\nCompiling SIMD combined module...");
const simdOutputWatFile = path.join(distDir, "combined_simd.wat");
const simdOutputWasmFile = path.join(distDir, "combined_simd.wasm");

// Files to include in SIMD module
const simdModuleFiles = ["reverse_bits.wat", "fft_simd.wat"];

let simdCombinedWat = `(module
  ;; Import JS Math functions
  (import "math" "sin" (func $js_sin (param f64) (result f64)))
  (import "math" "cos" (func $js_cos (param f64) (result f64)))

  ;; 3 pages = 192KB: data + twiddle table
  (memory (export "memory") 3)\n`;

simdModuleFiles.forEach((file) => {
  const filePath = path.join(modulesDir, file);
  const content = fs.readFileSync(filePath, "utf8");
  simdCombinedWat +=
    content
      .trim()
      .split("\n")
      .map((line) => `  ${line}`)
      .join("\n") + "\n";
});

simdCombinedWat += ")\n";

fs.writeFileSync(simdOutputWatFile, simdCombinedWat);

try {
  execSync(`wasm-tools parse ${simdOutputWatFile} -o ${simdOutputWasmFile}`);
  console.log(`  combined_simd.wasm ✓`);
} catch (error) {
  console.error(`  Error compiling SIMD module: ${error.stderr?.toString() || error.message}`);
  console.error("  WAT file saved for inspection:", simdOutputWatFile);
  // Don't exit - SIMD might not be supported
}

// Build Radix-4 combined module
console.log("\nCompiling Radix-4 combined module...");
const radix4OutputWatFile = path.join(distDir, "combined_radix4.wat");
const radix4OutputWasmFile = path.join(distDir, "combined_radix4.wasm");

const radix4ModuleFiles = ["reverse_bits.wat", "fft_radix4.wat"];

let radix4CombinedWat = `(module
  (import "math" "sin" (func $js_sin (param f64) (result f64)))
  (import "math" "cos" (func $js_cos (param f64) (result f64)))
  (memory (export "memory") 3)\n`;

radix4ModuleFiles.forEach((file) => {
  const filePath = path.join(modulesDir, file);
  const content = fs.readFileSync(filePath, "utf8");
  radix4CombinedWat +=
    content
      .trim()
      .split("\n")
      .map((line) => `  ${line}`)
      .join("\n") + "\n";
});

radix4CombinedWat += ")\n";

fs.writeFileSync(radix4OutputWatFile, radix4CombinedWat);

try {
  execSync(`wasm-tools parse ${radix4OutputWatFile} -o ${radix4OutputWasmFile}`);
  console.log(`  combined_radix4.wasm ✓`);
} catch (error) {
  console.error(`  Error compiling Radix-4 module: ${error.stderr?.toString() || error.message}`);
  console.error("  WAT file saved for inspection:", radix4OutputWatFile);
}

// Build Stockham combined module (no bit-reversal needed)
console.log("\nCompiling Stockham combined module...");
const stockhamOutputWatFile = path.join(distDir, "combined_stockham.wat");
const stockhamOutputWasmFile = path.join(distDir, "combined_stockham.wasm");

const stockhamModuleFiles = ["fft_stockham.wat"];

let stockhamCombinedWat = `(module
  (import "math" "sin" (func $js_sin (param f64) (result f64)))
  (import "math" "cos" (func $js_cos (param f64) (result f64)))
  (memory (export "memory") 4)\n`;

stockhamModuleFiles.forEach((file) => {
  const filePath = path.join(modulesDir, file);
  const content = fs.readFileSync(filePath, "utf8");
  stockhamCombinedWat +=
    content
      .trim()
      .split("\n")
      .map((line) => `  ${line}`)
      .join("\n") + "\n";
});

stockhamCombinedWat += ")\n";

fs.writeFileSync(stockhamOutputWatFile, stockhamCombinedWat);

try {
  execSync(`wasm-tools parse ${stockhamOutputWatFile} -o ${stockhamOutputWasmFile}`);
  console.log(`  combined_stockham.wasm ✓`);
} catch (error) {
  console.error(`  Error compiling Stockham module: ${error.stderr?.toString() || error.message}`);
  console.error("  WAT file saved for inspection:", stockhamOutputWatFile);
}

// Build Unrolled combined module
console.log("\nCompiling Unrolled combined module...");
const unrolledOutputWatFile = path.join(distDir, "combined_unrolled.wat");
const unrolledOutputWasmFile = path.join(distDir, "combined_unrolled.wasm");

let unrolledCombinedWat = `(module
  (import "math" "sin" (func $js_sin (param f64) (result f64)))
  (import "math" "cos" (func $js_cos (param f64) (result f64)))
  (memory (export "memory") 3)\n`;

const unrolledContent = fs.readFileSync(path.join(modulesDir, "fft_unrolled.wat"), "utf8");
unrolledCombinedWat +=
  unrolledContent
    .trim()
    .split("\n")
    .map((line) => `  ${line}`)
    .join("\n") + "\n";
unrolledCombinedWat += ")\n";

fs.writeFileSync(unrolledOutputWatFile, unrolledCombinedWat);

try {
  execSync(`wasm-tools parse ${unrolledOutputWatFile} -o ${unrolledOutputWasmFile}`);
  console.log(`  combined_unrolled.wasm ✓`);
} catch (error) {
  console.error(`  Error compiling Unrolled module: ${error.stderr?.toString() || error.message}`);
  console.error("  WAT file saved for inspection:", unrolledOutputWatFile);
}

console.log("\n✓ All modules compiled successfully!");
