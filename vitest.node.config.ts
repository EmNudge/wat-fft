import { defineConfig } from "vitest/config";

// Minimal vitest config for node-based debug tools
export default defineConfig({
  test: {
    include: ["tools/**/*.js"],
  },
});
