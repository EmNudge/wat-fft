import { defineConfig } from "vitest/config";
import path from "path";

export default defineConfig({
  test: {
    // Browser mode configuration for benchmarks
    browser: {
      enabled: true,
      provider: "playwright",
      instances: [{ browser: "chromium" }],
      headless: true,
    },
    // Benchmark configuration
    benchmark: {
      include: ["benchmarks/browser/**/*.bench.ts"],
      reporters: ["default"],
    },
    // Include pattern for benchmark files
    include: ["benchmarks/browser/**/*.bench.ts"],
  },
  // Serve WASM files correctly
  assetsInclude: ["**/*.wasm"],
  publicDir: false,
  server: {
    fs: {
      // Allow serving files from project root
      allow: ["."],
    },
  },
  resolve: {
    alias: {
      // Allow importing from dist directory
      "@dist": path.resolve(__dirname, "dist"),
    },
  },
});
