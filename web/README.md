# binnacle web

The browser SPA: Gren + Vite + Tailwind CSS v4 + daisyUI, styled with the
Bubbletea TUI design system.

**Scope.** This is the *design stack* — the CSS layer, the HTML shell, and the
`Ui.*` component library, with a gallery page (`Main.gren`) that exercises all
of it. The fleet application itself — routing, the wire contract in
`packages/core`, the Gren server — lands with the bootstrap story.

Governing: [ADR-0001](../docs/adrs/ADR-0001-gren-fullstack-base-stack.md) ·
[ADR-0002](../docs/adrs/ADR-0002-stumpcloud-fleet-taxonomy.md) ·
[design language](../docs/design/README.md)

## Commands

```sh
npm install        # once
npm run dev        # vite dev server on :5173, recompiles Gren on save
npm run build      # production bundle into dist/
npm run check      # gren make Main — type-check without emitting
```

From the repo root, `make check` runs the same Gren type-check.

There is deliberately **no `tailwind.config.js` and no `postcss.config.js`**.
Tailwind v4 is configured in CSS; the whole configuration is
`src/styles/theme.css`.

## Layout

```
web/
  index.html              page shell — theme bootstrap, fonts, mount point
  vite.config.js          gren() then tailwindcss() — order matters, see below
  gren.json               pinned compiler + exact dependency versions
  gren_packages/          vendored deps, COMMITTED (ADR-0001: offline builds)
  src/
    main.js               the only JS we own: import CSS, init Gren with flags
    Main.gren             gallery app — exercises every component
    Ui/                   the component library
      Theme.gren          Night/Day + the localStorage contract
      Status.gren         Up/Degraded/Down/Unknown → glyph + hue
      Button.gren         daisyUI btn + the Bubbletea treatment
      Badge.gren          status chips, counts, pixel eyebrows
      Panel.gren          the card — Lip Gloss rounded box
      Table.gren          fleet table, generic over row type
      Meter.gren          metric bars with per-metric thresholds
      Feedback.gren       spinners, block cursor, help footer
      Terminal.gren       embedded terminal — real TTY output ONLY
      Icon.gren           Lucide frame + curated allowlist
    styles/
      app.css             entry point; the only stylesheet index.html loads
      theme.css           tokens → Tailwind @theme → daisyUI themes → base
      tokens/             vendored design tokens — DO NOT EDIT
```

## Three things that will bite you

**1. Plugin order in `vite.config.js` is load-bearing.** `gren()` must run
before `tailwindcss()`, so the compiled Gren output exists when Tailwind scans
for class names. Reversed, every utility used only from a `.gren` file gets
tree-shaken out and the app renders unstyled — a failure that looks like a CSS
bug and is not.

**2. Class names are unchecked strings.** ADR-0001 accepted this: no typed-CSS
codegen exists for Gren, so a typo in `class "bg-surfce"` compiles fine and
silently does nothing. The mitigation is that components own their class
strings — view code composes `Ui.*` functions rather than writing utilities
inline, so there is one place per component for a typo to hide, and the gallery
renders all of them.

**3. `vite-plugin-gren` pins `vite@7.x`.** Vite 8 is out; installing it produces
an `ERESOLVE` conflict. The version here is pinned to 7 deliberately rather than
forced through with `--legacy-peer-deps`.

## Theming

One attribute — `data-theme` on `<html>`, values `night` (default) and `day`.
It drives the design tokens and daisyUI simultaneously. No component contains a
`dark:` variant; see [the design language doc](../docs/design/README.md#why-no-dark-variants-anywhere)
for why that works.

## Testing

No test suite yet — `gren-lang/test` arrives with the bootstrap story, and
`make test` is an honest no-op until then. When it lands, the component library
is unusually easy to test for a UI layer: every component returns
`Transmutable.Html`, which renders to a string via `Transmutable.Html.toString`
without a DOM. That is the reason the components speak `Transmutable.Html` and
convert to virtual DOM once, at the `Browser.element` boundary in `Main.gren`,
rather than using `gren-lang/browser`'s `Html` throughout.
