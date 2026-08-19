import { defineConfig } from "vite";
import tailwindcss from "@tailwindcss/vite";

// Governing: ADR-0004 (Vite + Tailwind CSS v4 + daisyUI as the CSS framework).
//
// Tailwind v4 is a Vite plugin, not a PostCSS step — there is deliberately no
// postcss.config.js and no tailwind.config.js in this project. The whole
// Tailwind and daisyUI configuration is CSS, in assets/styles/theme.css.
//
// Tailwind must also scan the HEEx class strings in server/lib, which the
// @source directive in theme.css covers, so utilities used only from a
// .ex/.heex file are not tree-shaken out of the bundle.
export default defineConfig(({ command }) => ({
  plugins: [tailwindcss()],

  build: {
    outDir: "priv/static/assets",
    emptyOutDir: true,
    // Unhashed filenames: the container image is immutable, so the filename
    // never goes stale behind a cache, and the root layout can reference
    // /assets/app.js statically without a Vite manifest reader.
    assetsDir: "",
    rollupOptions: {
      input: "assets/js/app.js",
      output: {
        entryFileNames: "app.js",
        chunkFileNames: "[name].js",
        assetFileNames: "[name][extname]",
      },
    },
    sourcemap: command === "build",
  },

  server: {
    port: 5173,
    strictPort: true,
  },
}));
