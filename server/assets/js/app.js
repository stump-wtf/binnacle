// Vite entry point — the only JavaScript binnacle owns.
//
// Governing: ADR-0004 (Elixir full-stack; Phoenix LiveView + Vite).
//
// Everything here is glue the LiveView cannot express: importing the
// stylesheet so Vite/Tailwind processes it, starting the LiveView socket,
// and the ThemeSync hook that keeps <html data-theme> and localStorage in
// step with the server's theme assign. Application logic belongs in Elixir —
// if this file starts growing, something has escaped the server.

import "../styles/app.css";
import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";

const Hooks = {
  // One decision-maker for the theme attribute. The layout's bootstrap script
  // resolved it before first paint; on mount we report that value to the
  // server (so its assign agrees with the pixels), and on every server-driven
  // update we push the new value to <html> and remember it in localStorage.
  ThemeSync: {
    mounted() {
      const theme = document.documentElement.getAttribute("data-theme");
      if (theme) this.pushEvent("theme-sync", { theme });
    },
    updated() {
      const theme = this.el.getAttribute("data-theme");
      if (!theme) return;
      document.documentElement.setAttribute("data-theme", theme);
      try {
        localStorage.setItem("binnacle-theme", theme);
      } catch (e) {
        /* storage disabled: the toggle just won't persist */
      }
    },
  },
};

const csrfToken = document
  .querySelector("meta[name='csrf-token']")
  .getAttribute("content");
const liveSocket = new LiveSocket("/live", Socket, {
  params: { _csrf_token: csrfToken },
  hooks: Hooks,
});
liveSocket.connect();
