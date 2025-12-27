import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import { execSync } from 'child_process';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const modulesDir = path.join(__dirname, 'modules');
const distDir = path.join(__dirname, 'dist');

// Ensure dist directory exists
if (!fs.existsSync(distDir)) {
  fs.mkdirSync(distDir);
}

const watFiles = fs.readdirSync(modulesDir).filter(file => file.endsWith('.wat'));

// Modules that have dependencies and can't be compiled standalone
const dependentModules = ['fft_main.wat'];

// Compile individual standalone modules
console.log('Compiling individual modules...');
watFiles.forEach(file => {
  // Skip modules that have dependencies
  if (dependentModules.includes(file)) {
    console.log(`  ${path.basename(file, '.wat')} (skipped - has dependencies)`);
    return;
  }

  const filePath = path.join(modulesDir, file);
  const content = fs.readFileSync(filePath, 'utf8');
  const moduleName = path.basename(file, '.wat');

  // Check if the file is already a complete module
  const isCompleteModule = content.trim().startsWith('(module');

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
    execSync(`wat2wasm ${outputWatFile} -o ${outputWasmFile}`);
    console.log(`  ${moduleName}.wasm ✓`);
  } catch (error) {
    console.error(`  Error compiling ${moduleName}: ${error.message}`);
    process.exit(1);
  }
});

// Build combined module
console.log('\nCompiling combined module...');
const outputWatFile = path.join(distDir, 'combined.wat');
const outputWasmFile = path.join(distDir, 'combined.wasm');

let combinedWat = `(module
  (memory (export "memory") 1)\n`;

watFiles.forEach(file => {
  const filePath = path.join(modulesDir, file);
  const content = fs.readFileSync(filePath, 'utf8');

  // Skip the module wrapper in math_trig.wat if it's there
  const processedContent = file === 'math_trig.wat'
    ? content.replace(/^\(module\s*/, '').replace(/\s*\)$/, '') // Remove (module ... ) wrapper
    : content;

  combinedWat += processedContent.trim().split('\n').map(line => `  ${line}`).join('\n') + '\n';
});

combinedWat += ')\n';

fs.writeFileSync(outputWatFile, combinedWat);

try {
  execSync(`wat2wasm ${outputWatFile} -o ${outputWasmFile}`);
  console.log(`  combined.wasm ✓`);
} catch (error) {
  console.error(`  Error compiling combined module: ${error.message}`);
  process.exit(1);
}

console.log('\n✓ All modules compiled successfully!');

