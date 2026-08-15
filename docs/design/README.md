# binnacle — design language

binnacle is styled with the **Bubbletea TUI design system**: a terminal-native
system built on the Charm ecosystem's visual language (Lip Gloss rounded
borders, monospace type, ANSI neon on blue-black) pushed toward a
cutesy-cyberpunk / Tron direction.

This document is the binnacle-specific reading of that system — what it means
for a fleet monitor, and which parts of it are load-bearing here. It is not a
copy of the system's own guide.

> The system is original work inspired by the open-source Charm ecosystem. It is
> not the official Charm brand and reproduces neither Charm's logo nor its
> commercial typefaces.

## Where the system lives

| Thing | Location |
|---|---|
| Design tokens (vendored, do not edit) | [`web/src/styles/tokens/`](../../web/src/styles/tokens/) |
| Tailwind + daisyUI bridge (ours) | [`web/src/styles/theme.css`](../../web/src/styles/theme.css) |
| Gren component library | [`web/src/Ui/`](../../web/src/Ui/) |
| Docs-site copy of the tokens | `docs-site/src/css/tokens/` |

The tokens are vendored twice — once for the app's Vite build, once for the
Docusaurus site — because the two have separate build systems. Both copies come
from the same upstream export and neither is hand-edited, so they cannot drift
silently; a token change is a re-vendor in both places.

## Which dialect binnacle speaks

The design system explicitly speaks **two** dialects, and says to decide which
one you are in *before* designing. binnacle is not free to pick per screen.

**The app is the HTML/HTMX (browser) dialect.** No window chrome, content
directly on the page canvas, web-scale spacing (`--container-web` 1160px), the
richer hover and motion. It is a dashboard on a big screen, not a 900px terminal
window.

**The one exception is `Ui.Terminal`.** The system's rule:

> A framed window on a web surface means exactly one thing: *a literal embedded
> terminal*. Never wrap web content in fake terminal chrome.

So terminal chrome appears around `docker logs`, a `systemctl status` dump, an
SSH session — output that genuinely came from a TTY — and nowhere else. A
dashboard panel that wants to look "terminal-y" uses `Ui.Panel`. Getting this
wrong is the single fastest way to make the whole surface read as a costume.

Two rules follow from an embedded terminal being a real terminal:

- **It stays night in both themes.** A terminal emulator does not repaint its
  scrollback when the surrounding page goes light, and flipping it would wreck
  the ANSI colour relationships in the output it is displaying. `Ui.Terminal`
  pins `data-theme="night"` on its own frame.
- **The chrome may glow; the body may not.** The frame is the OS layer, so it
  gets a real drop shadow and a faint bloom. Inside, emphasis is colour and
  weight only — a character cell cannot paint a shadow.

## Theming: one attribute, three states

Everything keys off `data-theme` on `<html>`:

- The design tokens re-point every custom property under `[data-theme="day"]`.
- daisyUI switches components on the same attribute — which is exactly why the
  two themes are *named* `night` and `day` rather than daisyUI's stock
  `dark`/`light`. One attribute, one switch, no way for the two layers to
  disagree.
- daisyUI's built-in `light`/`dark` themes are disabled (`themes: false`).
  They would answer to the same attribute under names the tokens do not
  recognise, giving a half-applied theme that looks like a CSS bug.

The three states are: an explicit stored choice wins; otherwise follow
`prefers-color-scheme`; the markup default is night. Only an *explicit* choice
is persisted (`binnacle-theme` in `localStorage`) — storing the resolved value
would pin a user who never chose to whatever their OS happened to say the first
time they loaded the page.

Resolution happens in an inline script in `index.html`, above the stylesheet
link, so it runs before first paint. Gren reads the result back through flags
rather than re-deriving it: two independent resolutions are two chances to
disagree, and the disagreement is visible as a flash.

### Why no `dark:` variants anywhere

`theme.css` bridges the tokens into Tailwind with `@theme inline`. The keyword
is load-bearing. A plain `@theme` copies each value once at build time, freezing
the night palette into the utility. With `inline`, `bg-surface` compiles to
`background-color: var(--bg-surface)` — the *token* — which the design system
re-points per theme.

You can see it in the built CSS:

```css
.text-ok { color: var(--role-success) }
```

So one class is correct in both palettes, and no component needs a theme branch.
If you ever find yourself writing a `dark:` variant in this codebase, the token
layer is missing something — fix it there.

## Colour is never the only signal

Status appears at every level of the taxonomy (ADR-0002), and `Ui.Status` is the
one place that decides what each state looks like:

| Status | Glyph | Hue | Meaning |
|---|---|---|---|
| `Up` | `●` | mint | answering, nominal |
| `Degraded` | `▲` | gold | answering, over a threshold |
| `Down` | `✗` | coral | not answering |
| `Unknown` | `○` | dim grey | no probe result |

Two deliberate choices:

- **`Unknown` is grey, not red.** "The probe did not answer" is not "the host is
  down". Colouring them alike manufactures outages out of monitoring gaps.
- **Every status renders glyph + hue + word.** The state survives a copy-paste
  into Signal, and it is readable by anyone who cannot separate the hues.

Glyphs rather than an icon set is the system's own iconography rule: terminal
UIs use Unicode and box-drawing characters, so we type the glyph rather than
reaching for a web icon font.

## Metrics

`Ui.Meter` carries **per-metric thresholds**, not one global pair. 85% memory is
unremarkable; 85 °C on a CPU package is not. A single "warn at 80" would either
cry wolf about memory or stay silent about heat.

| Metric | Warn | Danger |
|---|---|---|
| CPU | 80% | 95% |
| Memory | 75% | 90% |
| Temperature | 80 °C | 90 °C |

A nominal bar uses the neon gradient ramp; anything over a threshold goes flat
in the alert hue. A gradient at 95% CPU would put mint at the left edge of a bar
that means trouble.

Numeric table columns are `tabular-nums` and right-aligned. Proportional digits
make a vertical scan useless because the decimal points wander.

## Motion

Quick and springy — `--ease-spring` for button lifts, `--ease-out` for bars,
120–340ms. The blinking block cursor (`cursor-block`, `steps(1)`, 1.06s) is the
heartbeat and is CSS rather than Gren so it keeps blinking while the app is idle.

Spinners cycle glyph frames from a tick in the model, not from CSS animation, so
every spinner on the page stays in lockstep off one subscription instead of
drifting on its own clock.

**Never `transition: all`.** The system calls this out and the reason is real:
`all` catches the initial style application and can animate layout properties on
first paint. Every transition in `Ui.*` lists its properties explicitly.

`prefers-reduced-motion` freezes the cursor and spinners.

## Typography

Monospace throughout — that is the brand, not a code-block choice.

- **JetBrains Mono** (`--font-mono`) — body, UI, code
- **Space Mono** (`--font-display`) — headings and wordmarks
- **Silkscreen** (`--font-pixel`) — pixel eyebrows and badges only

Hierarchy comes from weight, size and colour, never from switching to a
proportional face. Uppercase is reserved for two things: pixel eyebrows
(`// FLEET`) and status-bar modes (`NORMAL`, `FOLLOWING`). Everything else is
lowercase — the system's voice is playful and lowercase, and `binnacle` is
spelled lowercase for the same reason.

These are free substitutes for the commercial faces Charm's own surfaces use.
If the real faces are ever licensed, drop them in and re-point `--font-mono` /
`--font-display`; nothing else changes.

## Icons

`Ui.Icon` is the hand-curated allowlist ADR-0001 asks for, plus the frame every
Lucide icon shares: 24×24, `fill="none"`, `stroke="currentColor"`, 2px stroke,
round caps and joins.

`currentColor` is the load-bearing part — an icon inherits `text-ok` /
`text-danger` from its container, so the status hues apply to icons with no
per-icon colour handling.

Path data is copied verbatim from `lucide-static` (pinned as a devDependency, so
the copies can be diffed against their source). Nine icons is enough for the
fleet views. Adding a tenth by hand is fine; adding a hundredth is the signal to
write the codegen tool ADR-0001 describes — the frame is already the contract it
would emit against.

## Content voice

Lowercase, warm, concrete, a little cheeky, never corporate. Address the user as
*you*. Errors stay gentle.

Every screen ends with a help footer of `key action` pairs joined by bullets —
`↑/↓ navigate • enter select • q quit`. The system calls this "a load-bearing
convention, not decoration", and `Ui.Feedback.keyHint` exists so it is easier to
include than to omit.

Emoji only where Charm itself uses them (the `moon` spinner, prose flourishes),
never as bullets or inside dense UI.
