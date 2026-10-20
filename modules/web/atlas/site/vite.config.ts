import { defineConfig } from "vite";

// The data is not part of the build: atlas-scan writes it to /data on the
// server, and `public/data/atlas.json` (git-ignored) stands in for it in dev.
export default defineConfig({
  build: { target: "es2022", chunkSizeWarningLimit: 800 },
});
