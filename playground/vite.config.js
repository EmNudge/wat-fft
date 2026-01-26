import { defineConfig } from "vite";
import { resolve } from "path";
import { readdirSync, existsSync, readFileSync } from "fs";

// Plugin to serve WASM files from parent dist directory
function wasmServePlugin() {
  const distDir = resolve(__dirname, "../dist");

  return {
    name: "wasm-serve",
    configureServer(server) {
      server.middlewares.use((req, res, next) => {
        if (req.url && req.url.startsWith("/wasm/")) {
          const filename = req.url.replace("/wasm/", "");
          const filepath = resolve(distDir, filename);

          if (existsSync(filepath)) {
            const content = readFileSync(filepath);
            res.setHeader("Content-Type", "application/wasm");
            res.end(content);
            return;
          }
        }
        next();
      });
    },
  };
}

// Plugin to expose sample files from public/samples as a virtual module
function sampleFilesPlugin() {
  const virtualModuleId = "virtual:sample-files";
  const resolvedVirtualModuleId = "\0" + virtualModuleId;

  return {
    name: "sample-files",
    resolveId(id) {
      if (id === virtualModuleId) {
        return resolvedVirtualModuleId;
      }
    },
    load(id) {
      if (id === resolvedVirtualModuleId) {
        const samplesDir = resolve(__dirname, "public/samples");
        try {
          const files = readdirSync(samplesDir)
            .filter((f) => /\.(wav|mp3|ogg|flac)$/i.test(f))
            .sort();
          const samples = files.map((f) => ({
            value: `/samples/${f}`,
            label: f,
          }));
          return `export default ${JSON.stringify(samples)};`;
        } catch {
          return "export default [];";
        }
      }
    },
  };
}

export default defineConfig({
  plugins: [wasmServePlugin(), sampleFilesPlugin()],
  root: ".",
  publicDir: "public",
  server: {
    fs: {
      // Allow serving files from the parent dist directory
      allow: [".."],
    },
    headers: {
      "Cross-Origin-Opener-Policy": "same-origin",
      "Cross-Origin-Embedder-Policy": "require-corp",
    },
  },
  build: {
    target: "esnext",
    outDir: "dist",
    rollupOptions: {
      input: {
        main: resolve(__dirname, "index.html"),
      },
    },
  },
  preview: {
    headers: {
      "Cross-Origin-Opener-Policy": "same-origin",
      "Cross-Origin-Embedder-Policy": "require-corp",
    },
  },
  optimizeDeps: {
    exclude: ["*.wasm"],
  },
});
