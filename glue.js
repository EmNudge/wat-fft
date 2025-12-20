import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import { execSync } from 'child_process';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const modulesDir = path.join(__dirname, 'modules');
const distDir = path.join(__dirname, 'dist');
const outputWatFile = path.join(distDir, 'combined.wat');
const outputWasmFile = path.join(distDir, 'combined.wasm');

const watFiles = fs.readdirSync(modulesDir).filter(file => file.endsWith('.wat'));

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

// Ensure dist directory exists
if (!fs.existsSync(distDir)) {
  fs.mkdirSync(distDir);
}

fs.writeFileSync(outputWatFile, combinedWat);
console.log(`Combined WAT written to ${outputWatFile}`);

try {
  execSync(`wat2wasm ${outputWatFile} -o ${outputWasmFile}`);
  console.log(`Combined WASM written to ${outputWasmFile}`);
} catch (error) {
  console.error(`Error compiling WAT to WASM: ${error.message}`);
  process.exit(1);
}

