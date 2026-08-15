// Vite entry point — the only JavaScript binnacle's web app owns.
//
// Governing: ADR-0001 (Gren full-stack; Vite + gren-lang/vite-plugin-gren).
//
// Everything here is glue that Gren cannot express: importing the stylesheet so
// Vite/Tailwind processes it, and handing the app its flags. Application logic
// belongs in Gren — if this file starts growing, something has escaped the type
// system.

import "./styles/app.css";

// vite-plugin-gren compiles a .gren entry into a module with a single named
// export, `Gren`, whose keys are the compiled Gren modules — hence
// `Gren.Main`, not a default export.
import { Gren } from "./Main.gren";

// The bootstrap script in index.html has already resolved the theme and written
// it onto <html>, before first paint. Read it back rather than re-deriving it:
// two independent resolutions are two chances to disagree, and the disagreement
// shows up as a flash.
const theme = document.documentElement.getAttribute("data-theme") ?? "night";

Gren.Main.init({
  node: document.getElementById("app"),
  flags: { theme },
});
