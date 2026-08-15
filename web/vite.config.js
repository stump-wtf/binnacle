import { defineConfig } from "vite";
import gren from "vite-plugin-gren";
import tailwindcss from "@tailwindcss/vite";

// Governing: ADR-0001 (Vite + the official gren-lang/vite-plugin-gren;
// Tailwind CSS v4 + daisyUI as the CSS framework).
//
// Tailwind v4 is a Vite plugin now, not a PostCSS step — there is deliberately
// no postcss.config.js and no tailwind.config.js in this project. The whole
// Tailwind and daisyUI configuration is CSS, in src/styles/theme.css.
//
// Plugin order matters: gren() must run before tailwindcss() so the compiled
// Gren output is on disk when Tailwind scans for class names. Reversed, every
// utility used only from a .gren file gets tree-shaken out of the bundle and
// the app renders unstyled — a failure that looks like a CSS bug and is not.
export default defineConfig(({ command }) => ({
  plugins: [
    gren({
      // Readable output and a working Debug module while developing; the
      // optimizer only for the real build, where it is what makes the bundle
      // small enough to be worth shipping uncompressed over the LAN.
      optimize: command === "build",
      sourcemaps: true,
    }),
    tailwindcss(),
  ],

  build: {
    outDir: "dist",
    // The Gren server serves these as plain files from disk (ADR-0001: there is
    // no asset-embedding story), so hashed names are what makes them safely
    // cacheable behind Caddy.
    assetsDir: "assets",
    sourcemap: true,
  },

  server: {
    port: 5173,
    strictPort: true,
  },
}));
