import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";

// `npm run dev` proxies the API to a yeoman serving on this address.
const yeoman = "http://127.0.0.1:8950";
export default defineConfig({
  plugins: [react(), tailwindcss()],
  server: {
    proxy: {
      "/api": yeoman,
      "/login": yeoman,
    },
  },
});
