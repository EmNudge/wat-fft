import { execSync } from "child_process";
import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const modulesDir = path.join(__dirname, "modules");
const buildDir = path.join(__dirname, "build");
const distDir = path.join(__dirname, "dist");
const witDir = path.join(__dirname, "wit", "worlds");

// Ensure directories exist
[buildDir, distDir].forEach((dir) => {
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
});

// Module definitions
const modules = {
  // Standalone modules - no dependencies, can be built as simple wasm or components
  standalone: [
    {
      name: "reverse_bits",
      wit: "bit-reversal.wit",
      world: "bit-reversal-component",
      exports: ["reverse-bits"],
    },
    {
      name: "swap",
      wit: "mem-swap.wit",
      world: "mem-swap-component",
      exports: ["swap"],
      memory: 1,
    },
    {
      name: "math_trig",
      isComplete: true, // Already a complete module
    },
  ],

  // FFT variants with their dependencies and imports
  fft: [
    {
      name: "fft_stockham",
      wit: "fft-stockham.wit",
      world: "fft-stockham",
      imports: { sin: "f64->f64", cos: "f64->f64" },
      exports: ["precompute-twiddles", "fft-stockham"],
      memory: 4,
      deps: [], // No wasm dependencies
    },
    {
      name: "fft_radix4",
      wit: "fft-radix4.wit",
      world: "fft-radix4",
      imports: { sin: "f64->f64", cos: "f64->f64" },
      exports: ["precompute-twiddles", "fft-radix4"],
      memory: 3,
      deps: ["reverse_bits"],
    },
    {
      name: "fft_fast",
      wit: "fft-fast.wit",
      world: "fft-fast",
      imports: { sin: "f64->f64", cos: "f64->f64" },
      exports: ["precompute-twiddles", "fft-fast"],
      memory: 3,
      deps: ["reverse_bits"],
    },
    {
      name: "fft_simd",
      wit: "fft-simd.wit",
      world: "fft-simd",
      imports: { sin: "f64->f64", cos: "f64->f64" },
      exports: ["precompute-twiddles", "fft-simd"],
      memory: 3,
      deps: ["reverse_bits"],
    },
    {
      name: "fft_unrolled",
      wit: "fft-unrolled.wit",
      world: "fft-unrolled",
      imports: { sin: "f64->f64", cos: "f64->f64" },
      exports: ["precompute-twiddles", "fft-unrolled"],
      memory: 3,
      deps: [],
    },
  ],
};

function run(cmd, description) {
  try {
    execSync(cmd, { stdio: "pipe", cwd: __dirname });
    return true;
  } catch (error) {
    console.error(`  Error: ${description || cmd}`);
    console.error(`  ${error.stderr?.toString() || error.message}`);
    return false;
  }
}

// Build standalone modules (legacy wasm format for backwards compat)
console.log("Building standalone modules (legacy format)...");
modules.standalone.forEach((mod) => {
  const srcPath = path.join(modulesDir, `${mod.name}.wat`);
  const content = fs.readFileSync(srcPath, "utf8");

  let moduleWat;
  if (mod.isComplete || content.trim().startsWith("(module")) {
    moduleWat = content;
  } else {
    const memoryPages = mod.memory || 1;
    moduleWat = `(module\n  (memory (export "memory") ${memoryPages})\n${content})\n`;
  }

  const outputWat = path.join(distDir, `${mod.name}.wat`);
  const outputWasm = path.join(distDir, `${mod.name}.wasm`);

  fs.writeFileSync(outputWat, moduleWat);
  if (run(`wasm-tools parse ${outputWat} -o ${outputWasm}`)) {
    console.log(`  ${mod.name}.wasm ✓`);
  }
});

// Build combined FFT modules (legacy format - what glue.js did)
console.log("\nBuilding combined FFT modules (legacy format)...");

function isCompleteModule(content) {
  return content.trim().startsWith("(module");
}

function extractModuleBody(content) {
  // Remove (module wrapper and closing paren, preserving inner content
  const lines = content.trim().split("\n");

  // Remove first line if it's "(module"
  if (lines[0].trim().startsWith("(module")) {
    lines.shift();
  }

  // Remove last line if it's just ")" or ") ;; end module"
  const lastLine = lines[lines.length - 1].trim();
  if (lastLine === ")" || lastLine === ") ;; end module") {
    lines.pop();
  }

  return lines.join("\n");
}

function buildCombinedModule(fft, outputName) {
  const srcPath = path.join(modulesDir, `${fft.name}.wat`);
  const content = fs.readFileSync(srcPath, "utf8");

  let combined;

  if (isCompleteModule(content)) {
    // Module is already complete with imports and memory
    // For legacy builds with deps, we need to inject the dependency code
    if (fft.deps.length === 0) {
      // No deps - use as-is
      combined = content;
    } else {
      // Has deps - need to inject them into the module
      let body = extractModuleBody(content);

      // Remove dependency imports (they'll be replaced by actual functions)
      // Remove "bits" import for reverse_bits
      body = body
        .split("\n")
        .filter((line) => !line.trim().startsWith('(import "bits"'))
        .join("\n");

      // Include dependencies
      let deps = "";
      for (const dep of fft.deps) {
        const depPath = path.join(modulesDir, `${dep}.wat`);
        const depContent = fs.readFileSync(depPath, "utf8");
        deps +=
          depContent
            .trim()
            .split("\n")
            .map((l) => `  ${l}`)
            .join("\n") + "\n";
      }

      // Find where to inject deps (after memory declaration)
      const lines = body.split("\n");
      const memoryLineIdx = lines.findIndex((l) => l.includes("(memory"));
      if (memoryLineIdx >= 0) {
        lines.splice(memoryLineIdx + 1, 0, deps);
      }

      combined = `(module\n${lines.join("\n")}\n)\n`;
    }
  } else {
    // Fragment - wrap with imports, memory, and deps (old behavior)
    let imports = "";
    if (fft.imports) {
      if (fft.imports.sin) {
        imports += '  (import "math" "sin" (func $js_sin (param f64) (result f64)))\n';
      }
      if (fft.imports.cos) {
        imports += '  (import "math" "cos" (func $js_cos (param f64) (result f64)))\n';
      }
    }

    let deps = "";
    for (const dep of fft.deps) {
      const depPath = path.join(modulesDir, `${dep}.wat`);
      const depContent = fs.readFileSync(depPath, "utf8");
      deps +=
        depContent
          .trim()
          .split("\n")
          .map((l) => `  ${l}`)
          .join("\n") + "\n";
    }

    const mainContent = content
      .trim()
      .split("\n")
      .map((l) => `  ${l}`)
      .join("\n");

    combined = `(module
${imports}  (memory (export "memory") ${fft.memory})
${deps}${mainContent}
)
`;
  }

  const outputWat = path.join(distDir, `${outputName}.wat`);
  const outputWasm = path.join(distDir, `${outputName}.wasm`);

  fs.writeFileSync(outputWat, combined);
  if (run(`wasm-tools parse ${outputWat} -o ${outputWasm}`)) {
    console.log(`  ${outputName}.wasm ✓`);
    return true;
  }
  return false;
}

// Build each FFT variant
modules.fft.forEach((fft) => {
  buildCombinedModule(fft, `combined_${fft.name.replace("fft_", "")}`);
});

// Also build the original combined.wat (radix-2 with embedded trig)
console.log("\nBuilding original combined module (radix-2 with embedded trig)...");
let originalCombined = '(module\n  (memory (export "memory") 1)\n';

// Extract body from complete modules, removing their wrapper/imports/memory
function extractFunctionBody(content) {
  let lines = content.split("\n");

  // Find and remove the opening (module line
  const moduleLineIdx = lines.findIndex((l) => l.trim().startsWith("(module"));
  if (moduleLineIdx >= 0) {
    lines.splice(moduleLineIdx, 1);
  }

  // Find and remove the closing ) that matches the module
  // It's typically the last line that is just ")" or ") ;; end module"
  for (let i = lines.length - 1; i >= 0; i--) {
    const trimmed = lines[i].trim();
    if (trimmed === ")" || trimmed === ") ;; end module") {
      lines.splice(i, 1);
      break;
    }
  }

  // Remove import and memory statements
  lines = lines.filter((line) => {
    const trimmed = line.trim();
    if (trimmed.startsWith("(import ")) return false;
    if (trimmed.startsWith("(memory ")) return false;
    return true;
  });

  return lines.join("\n");
}

// math_trig.wat provides embedded sin/cos (Taylor series)
const mathTrigContent = fs.readFileSync(path.join(modulesDir, "math_trig.wat"), "utf8");
originalCombined +=
  extractFunctionBody(mathTrigContent)
    .split("\n")
    .map((l) => `  ${l}`)
    .join("\n") + "\n";

// reverse_bits.wat - utility function used by fft_main
const reverseBitsContent = fs.readFileSync(path.join(modulesDir, "reverse_bits.wat"), "utf8");
originalCombined +=
  reverseBitsContent
    .trim()
    .split("\n")
    .map((l) => `  ${l}`)
    .join("\n") + "\n";

// fft_main.wat now uses $sin/$cos from math_trig and $reverse_bits
// Extract just the functions (skip imports/memory since it's now a complete module)
const fftMainContent = fs.readFileSync(path.join(modulesDir, "fft_main.wat"), "utf8");
originalCombined +=
  extractFunctionBody(fftMainContent)
    .split("\n")
    .map((l) => `  ${l}`)
    .join("\n") + "\n";

originalCombined += ")\n";
fs.writeFileSync(path.join(distDir, "combined.wat"), originalCombined);
if (
  run(
    `wasm-tools parse ${path.join(distDir, "combined.wat")} -o ${path.join(distDir, "combined.wasm")}`,
  )
) {
  console.log("  combined.wasm ✓");
}

// Build components (new format for testing with mocked dependencies)
console.log("\nBuilding components (new format)...");

// Export name mapping: snake_case in WAT -> kebab-case in WIT
const exportRenames = {
  precompute_twiddles: "precompute-twiddles",
  fft_stockham: "fft-stockham",
  fft_radix4: "fft-radix4",
  fft_fast: "fft-fast",
  fft_simd: "fft-simd",
  fft_unrolled: "fft-unrolled",
  reverse_bits: "reverse-bits",
};

// Generate component module from source WAT file
function generateComponentModule(fft) {
  const srcPath = path.join(modulesDir, `${fft.name}.wat`);
  let content = fs.readFileSync(srcPath, "utf8");

  // Rename exports from snake_case to kebab-case
  let processedContent = content;
  for (const [snakeCase, kebabCase] of Object.entries(exportRenames)) {
    const exportRegex = new RegExp(`\\(export\\s+"${snakeCase}"\\)`, "g");
    processedContent = processedContent.replace(exportRegex, `(export "${kebabCase}")`);
  }

  if (isCompleteModule(processedContent)) {
    // Complete module - replace namespaces with "$root" for component model
    let moduleWat = processedContent
      .replace(/\(import\s+"math"\s+"([^"]+)"/g, '(import "$root" "$1"')
      .replace(/\(import\s+"bits"\s+"reverse_bits"/g, '(import "$root" "reverse-bits"')
      .replace(/\(import\s+"stockham"\s+"([^"]+)"/g, '(import "$root" "$1"');

    return moduleWat;
  } else {
    // Fragment - wrap with imports, memory (old behavior)
    let imports = "";
    if (fft.imports?.cos) {
      imports += '  (import "$root" "cos" (func $js_cos (param f64) (result f64)))\n';
    }
    if (fft.imports?.sin) {
      imports += '  (import "$root" "sin" (func $js_sin (param f64) (result f64)))\n';
    }
    if (fft.deps?.includes("reverse_bits")) {
      imports +=
        '  (import "$root" "reverse-bits" (func $reverse_bits (param i32 i32) (result i32)))\n';
    }
    if (fft.deps?.includes("swap")) {
      imports += '  (import "$root" "swap" (func $swap (param i32 i32)))\n';
    }

    const mainContent = processedContent
      .trim()
      .split("\n")
      .map((l) => `  ${l}`)
      .join("\n");

    return `(module
${imports}  (memory (export "memory") ${fft.memory})
${mainContent}
)
`;
  }
}

function buildFFTComponent(fft) {
  const witPath = path.join(witDir, fft.wit);
  const moduleWatPath = path.join(buildDir, `${fft.name}_module.wat`);
  const corePath = path.join(buildDir, `${fft.name}.core.wasm`);
  const embeddedPath = path.join(buildDir, `${fft.name}.embedded.wasm`);
  const componentPath = path.join(buildDir, `${fft.name}.component.wasm`);

  // Check if WIT file exists
  if (!fs.existsSync(witPath)) {
    console.log(`  ${fft.name} (skipped - no WIT file)`);
    return false;
  }

  // Generate the module WAT from source
  const moduleWat = generateComponentModule(fft);
  fs.writeFileSync(moduleWatPath, moduleWat);

  // Build: WAT -> core.wasm -> embedded.wasm -> component.wasm
  if (!run(`wasm-tools parse ${moduleWatPath} -o ${corePath}`)) return false;
  if (
    !run(
      `wasm-tools component embed ${witPath} --world ${fft.world} ${corePath} -o ${embeddedPath}`,
    )
  )
    return false;
  if (!run(`wasm-tools component new ${embeddedPath} -o ${componentPath}`)) return false;

  console.log(`  ${fft.name}.component.wasm ✓`);
  return true;
}

// Build FFT components
modules.fft.forEach((fft) => {
  buildFFTComponent(fft);
});

// Build standalone components for composition
console.log("\nBuilding standalone components for composition...");

function buildStandaloneComponent(name, witFile, worldName, exportRename = null) {
  const srcPath = path.join(modulesDir, `${name}.wat`);
  const moduleWatPath = path.join(buildDir, `${name}_module.wat`);
  const corePath = path.join(buildDir, `${name}.core.wasm`);
  const embeddedPath = path.join(buildDir, `${name}.embedded.wasm`);
  const componentPath = path.join(buildDir, `${name}.component.wasm`);
  const witPath = path.join(witDir, witFile);

  // Read source and create module with kebab-case export
  let content = fs.readFileSync(srcPath, "utf8");
  if (exportRename) {
    content = content.replace(
      new RegExp(`\\(export "${exportRename.from}"\\)`),
      `(export "${exportRename.to}")`,
    );
  }
  const moduleWat = `(module\n${content
    .trim()
    .split("\n")
    .map((l) => `  ${l}`)
    .join("\n")}\n)\n`;
  fs.writeFileSync(moduleWatPath, moduleWat);

  if (!run(`wasm-tools parse ${moduleWatPath} -o ${corePath}`)) return false;
  if (
    !run(
      `wasm-tools component embed ${witPath} --world ${worldName} ${corePath} -o ${embeddedPath}`,
    )
  )
    return false;
  if (!run(`wasm-tools component new ${embeddedPath} -o ${componentPath}`)) return false;

  console.log(`  ${name}.component.wasm ✓`);
  return true;
}

buildStandaloneComponent("reverse_bits", "bit-reversal.wit", "bit-reversal-component", {
  from: "reverse_bits",
  to: "reverse-bits",
});

// Compose FFT components with their dependencies using wac
console.log("\nComposing components with wac...");

function composeComponent(fftName, plugComponents, outputName) {
  const socketPath = path.join(buildDir, `${fftName}.component.wasm`);
  const outputPath = path.join(distDir, `${outputName}.wasm`);

  const plugArgs = plugComponents
    .map((p) => `--plug ${path.join(buildDir, `${p}.component.wasm`)}`)
    .join(" ");

  if (run(`wac plug ${plugArgs} ${socketPath} -o ${outputPath}`)) {
    console.log(`  ${outputName}.wasm ✓`);
    return true;
  }
  return false;
}

// Compose FFT variants that need reverse_bits
composeComponent("fft_radix4", ["reverse_bits"], "fft_radix4_composed");
composeComponent("fft_fast", ["reverse_bits"], "fft_fast_composed");
composeComponent("fft_simd", ["reverse_bits"], "fft_simd_composed");

// These don't need composition (no external deps)
for (const name of ["fft_stockham", "fft_unrolled"]) {
  fs.copyFileSync(
    path.join(buildDir, `${name}.component.wasm`),
    path.join(distDir, `${name}_composed.wasm`),
  );
  console.log(`  ${name}_composed.wasm ✓ (no deps)`);
}

console.log("\n✓ Build complete!");
console.log("\nLegacy modules in dist/:");
console.log("  - combined_*.wasm (for WebAssembly.instantiate with {math: {sin, cos}})");
console.log("\nComposed components in dist/:");
console.log("  - *_composed.wasm (only need sin/cos imports, reverse-bits composed in)");
