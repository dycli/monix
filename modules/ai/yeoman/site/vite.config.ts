import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";

// `npm run dev` proxies the API to a yeoman serving on this address.
const yeoman = "http://127.0.0.1:8950";
export default defineConfig({
  plugins: [react(), tailwindcss()],
  // The same host serves the assistant's pages by name, so the build's
  // files sit under a name show_page refuses.
  build: { assetsDir: "_site" },
  server: {
    proxy: {
      "/api": yeoman,
      "/login": yeoman,
    },
  },
});
