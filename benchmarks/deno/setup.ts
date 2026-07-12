/**
 * Vendors a built copy of webgpu-fft (git@github.com:AICL-Lab/gpu-fft.git)
 * for the Deno GPU benchmark.
 *
 * The package is not published to npm and ships only a `dist` that must be
 * built from source, so we clone + build it into a gitignored vendor dir.
 * The GPU benchmark imports the built ESM from there.
 *
 *   deno run -A benchmarks/deno/setup.ts [--force]
 *
 * Idempotent: exits early if the vendored build already exists (pass --force
 * to rebuild).
 */

const REPO = "https://github.com/AICL-Lab/gpu-fft.git";
const HERE = new URL(".", import.meta.url).pathname;
const VENDOR = `${HERE}vendor`;
const SRC = `${VENDOR}/gpu-fft`;
const BUILT = `${SRC}/dist/index.js`;

async function run(cmd: string[], cwd?: string) {
  const [bin, ...args] = cmd;
  const p = new Deno.Command(bin, { args, cwd, stdout: "inherit", stderr: "inherit" });
  const { code } = await p.output();
  if (code !== 0) throw new Error(`\`${cmd.join(" ")}\` exited with ${code}`);
}

const force = Deno.args.includes("--force");

try {
  if (!force) {
    await Deno.stat(BUILT);
    console.log(`webgpu-fft already vendored at ${BUILT}`);
    Deno.exit(0);
  }
} catch {
  // not built yet — fall through
}

await Deno.mkdir(VENDOR, { recursive: true });
try {
  await Deno.stat(`${SRC}/.git`);
  console.log("Updating existing clone...");
  await run(["git", "-C", SRC, "pull", "--ff-only"]);
} catch {
  console.log(`Cloning ${REPO}...`);
  await run(["git", "clone", "--depth", "1", REPO, SRC]);
}

console.log("Installing deps + building webgpu-fft...");
await run(["npm", "install"], SRC);
await run(["npm", "run", "build"], SRC);

await Deno.stat(BUILT);
console.log(`\nwebgpu-fft built: ${BUILT}`);
