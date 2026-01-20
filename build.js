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

// ============================================================================
// Shared WAT Processing Utilities
// ============================================================================

/**
 * Check if content is a complete module (starts with "(module")
 */
function isCompleteModule(content) {
  return content.trim().startsWith("(module");
}

/**
 * Extract the body of a WAT module, removing the (module wrapper,
 * imports, and memory declarations.
 *
 * @param {string} content - WAT source content
 * @param {object} options - Processing options
 * @param {boolean} options.removeImports - Remove all import statements (default: true)
 * @param {boolean} options.removeMemory - Remove memory declarations (default: true)
 * @param {string[]} options.filterImportNamespaces - Only remove imports from these namespaces (if set)
 * @returns {string} Processed module body
 */
function extractModuleBody(content, options = {}) {
  const { removeImports = true, removeMemory = true, filterImportNamespaces = null } = options;

  let lines = content.trim().split("\n");

  // Remove opening (module line
  if (lines[0].trim().startsWith("(module")) {
    lines.shift();
  }

  // Remove closing ) that matches the module
  for (let i = lines.length - 1; i >= 0; i--) {
    const trimmed = lines[i].trim();
    if (trimmed === ")" || trimmed === ") ;; end module") {
      lines.splice(i, 1);
      break;
    }
  }

  // Filter out imports and memory based on options
  lines = lines.filter((line) => {
    const trimmed = line.trim();

    if (trimmed.startsWith("(import ")) {
      if (filterImportNamespaces !== null) {
        // Only remove imports from specific namespaces
        return !filterImportNamespaces.some((ns) => trimmed.includes(`"${ns}"`));
      }
      if (removeImports) {
        return false;
      }
    }

    if (removeMemory && trimmed.startsWith("(memory ")) {
      return false;
    }

    return true;
  });

  return lines.join("\n");
}

/**
 * Indent content by a specified number of spaces
 */
function indent(content, spaces = 2) {
  const prefix = " ".repeat(spaces);
  return content
    .split("\n")
    .map((line) => (line.trim() ? prefix + line : line))
    .join("\n");
}

/**
 * Load a dependency module and prepare it for embedding
 */
function loadDependency(depName) {
  const depPath = path.join(modulesDir, `${depName}.wat`);
  const content = fs.readFileSync(depPath, "utf8");
  return indent(content.trim(), 2);
}

// ============================================================================
// Shared Snippet System
// ============================================================================

/**
 * Parse shared.wat and extract snippets marked with @snippet
 * Returns { snippets: {name: code}, requires: {name: dependencyName} }
 */
function parseSharedSnippets() {
  const sharedPath = path.join(modulesDir, "shared.wat");
  if (!fs.existsSync(sharedPath)) {
    return { snippets: {}, requires: {} };
  }

  const content = fs.readFileSync(sharedPath, "utf8");
  const snippets = {};
  const requires = {};

  // Match @snippet markers and extract code until next marker or end of file
  // Format: ;; @snippet NAME\n[;; @requires DEP\n]CODE
  const lines = content.split("\n");
  let currentSnippet = null;
  let currentCode = [];

  for (const line of lines) {
    const snippetMatch = line.match(/^;;\s*@snippet\s+(\w+)/);
    const requiresMatch = line.match(/^;;\s*@requires\s+(\w+)/);

    if (snippetMatch) {
      // Save previous snippet if any
      if (currentSnippet) {
        snippets[currentSnippet] = currentCode.join("\n").trim();
      }
      currentSnippet = snippetMatch[1];
      currentCode = [];
    } else if (requiresMatch && currentSnippet) {
      requires[currentSnippet] = requiresMatch[1];
    } else if (currentSnippet) {
      // Skip comment-only lines at the start of a snippet
      if (currentCode.length === 0 && line.trim().startsWith(";;")) {
        continue;
      }
      currentCode.push(line);
    }
  }

  // Save last snippet
  if (currentSnippet) {
    snippets[currentSnippet] = currentCode.join("\n").trim();
  }

  return { snippets, requires };
}

/**
 * Load requested snippets with their dependencies resolved
 * Returns concatenated WAT code for all snippets in dependency order
 */
function loadSnippets(snippetNames) {
  const { snippets, requires } = parseSharedSnippets();
  const result = [];
  const added = new Set();

  function addSnippet(name) {
    if (added.has(name)) return;
    if (!snippets[name]) {
      console.warn(`  Warning: snippet "${name}" not found in shared.wat`);
      return;
    }
    // Add dependencies first
    if (requires[name]) {
      addSnippet(requires[name]);
    }
    added.add(name);
    result.push(snippets[name]);
  }

  snippetNames.forEach(addSnippet);
  return result.join("\n\n");
}

/**
 * Extract shared import names from WAT content
 * Returns array of imported names from "shared" namespace
 */
function extractSharedImports(content) {
  const imports = [];
  // Match both function and global imports from "shared" namespace
  const importRegex = /\(import\s+"shared"\s+"([^"]+)"/g;
  let match;
  while ((match = importRegex.exec(content)) !== null) {
    imports.push(match[1]);
  }
  return imports;
}

/**
 * Strip shared imports from WAT content
 * Removes import lines that import from "shared" namespace
 */
function stripSharedImports(content) {
  const lines = content.split("\n");
  const filteredLines = lines.filter((line) => {
    const trimmed = line.trim();
    return !trimmed.startsWith('(import "shared"');
  });
  return filteredLines.join("\n");
}

/**
 * Process WAT content to replace shared imports with actual implementations
 */
function inlineSharedImports(content) {
  // Extract what shared imports are used
  const sharedImports = extractSharedImports(content);
  if (sharedImports.length === 0) {
    return content;
  }

  // Strip the import declarations
  let processed = stripSharedImports(content);

  // Load the actual implementations
  const snippetCode = loadSnippets(sharedImports);

  if (snippetCode) {
    // Inject snippets after memory declaration
    const lines = processed.split("\n");
    const memoryLineIdx = lines.findIndex((l) => l.trim().startsWith("(memory"));
    if (memoryLineIdx >= 0) {
      lines.splice(memoryLineIdx + 1, 0, indent(snippetCode, 2));
      processed = lines.join("\n");
    }
  }

  return processed;
}

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
      deps: [],
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

function buildCombinedModule(fft, outputName) {
  const srcPath = path.join(modulesDir, `${fft.name}.wat`);
  let content = fs.readFileSync(srcPath, "utf8");

  // First, inline any shared imports
  content = inlineSharedImports(content);

  let combined;

  if (isCompleteModule(content)) {
    // Module is already complete with imports and memory
    if (fft.deps.length === 0) {
      // No deps - use as-is
      combined = content;
    } else {
      // Has deps - extract body and inject dependency code
      // Remove "bits" imports (will be replaced by actual dependency code)
      let body = extractModuleBody(content, {
        removeImports: false,
        removeMemory: false,
        filterImportNamespaces: ["bits"],
      });

      // Load and format dependencies
      const deps = fft.deps.map((dep) => loadDependency(dep)).join("\n");

      // Inject after memory declaration
      const lines = body.split("\n");
      const memoryLineIdx = lines.findIndex((l) => l.includes("(memory"));
      if (memoryLineIdx >= 0 && deps) {
        lines.splice(memoryLineIdx + 1, 0, deps);
      }

      combined = `(module\n${lines.join("\n")}\n)\n`;
    }
  } else {
    // Fragment - wrap with imports, memory, and deps
    let imports = "";
    if (fft.imports) {
      if (fft.imports.sin) {
        imports += '  (import "math" "sin" (func $js_sin (param f64) (result f64)))\n';
      }
      if (fft.imports.cos) {
        imports += '  (import "math" "cos" (func $js_cos (param f64) (result f64)))\n';
      }
    }

    const deps = fft.deps.map((dep) => loadDependency(dep)).join("\n");
    const mainContent = indent(content.trim(), 2);

    combined = `(module
${imports}  (memory (export "memory") ${fft.memory})
${deps}
${mainContent}
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

function buildOriginalCombined() {
  let combined = '(module\n  (memory (export "memory") 1)\n';

  // math_trig.wat provides embedded sin/cos (Taylor series)
  const mathTrigContent = fs.readFileSync(path.join(modulesDir, "math_trig.wat"), "utf8");
  combined += indent(extractModuleBody(mathTrigContent), 2) + "\n";

  // reverse_bits.wat - utility function used by fft_main
  combined += loadDependency("reverse_bits") + "\n";

  // fft_main.wat - extract just the functions
  const fftMainContent = fs.readFileSync(path.join(modulesDir, "fft_main.wat"), "utf8");
  combined += indent(extractModuleBody(fftMainContent), 2) + "\n";

  combined += ")\n";

  fs.writeFileSync(path.join(distDir, "combined.wat"), combined);
  if (
    run(
      `wasm-tools parse ${path.join(distDir, "combined.wat")} -o ${path.join(distDir, "combined.wasm")}`,
    )
  ) {
    console.log("  combined.wasm ✓");
    return true;
  }
  return false;
}

buildOriginalCombined();

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

/**
 * Apply export renames (snake_case to kebab-case) for component model
 */
function applyExportRenames(content, renames) {
  let result = content;
  for (const [snakeCase, kebabCase] of Object.entries(renames)) {
    const exportRegex = new RegExp(`\\(export\\s+"${snakeCase}"\\)`, "g");
    result = result.replace(exportRegex, `(export "${kebabCase}")`);
  }
  return result;
}

/**
 * Replace import namespaces for component model ($root namespace)
 */
function convertToComponentImports(content) {
  return content
    .replace(/\(import\s+"math"\s+"([^"]+)"/g, '(import "$root" "$1"')
    .replace(/\(import\s+"bits"\s+"reverse_bits"/g, '(import "$root" "reverse-bits"')
    .replace(/\(import\s+"stockham"\s+"([^"]+)"/g, '(import "$root" "$1"');
}

// Generate component module from source WAT file
function generateComponentModule(fft) {
  const srcPath = path.join(modulesDir, `${fft.name}.wat`);
  let content = fs.readFileSync(srcPath, "utf8");

  // Apply export renames
  content = applyExportRenames(content, exportRenames);

  // Inline shared imports (replaces "shared" namespace imports with actual implementations)
  content = inlineSharedImports(content);

  if (isCompleteModule(content)) {
    // Complete module - convert imports to component model format
    return convertToComponentImports(content);
  } else {
    // Fragment - wrap with component model imports and memory
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

    return `(module
${imports}  (memory (export "memory") ${fft.memory})
${indent(content.trim(), 2)}
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

  // Read source and apply export rename if needed
  let content = fs.readFileSync(srcPath, "utf8");
  if (exportRename) {
    content = applyExportRenames(content, { [exportRename.from]: exportRename.to });
  }

  // Wrap as module
  const moduleWat = `(module\n${indent(content.trim(), 2)}\n)\n`;
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
