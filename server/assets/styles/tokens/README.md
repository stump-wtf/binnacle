# Design tokens — vendored

These three files are vendored **verbatim** from the Bubbletea TUI design
system export:

```
docs/design/_ds/bubbletea-tui-design-system-5c2f3709-9093-45fd-9762-fbe0a39b6c7b/tokens/
```

`colors.css` · `typography.css` · `spacing.css`

Do not hand-edit them. They are the upstream contract: 187 custom properties,
with the night palette on `:root` and the day palette scoped to
`[data-theme="day"]`. To change a token, change it upstream in the design
system and re-vendor, so the docs site and the app cannot drift apart.

Everything binnacle adds sits in `../theme.css` instead — that file bridges
these tokens into Tailwind's `@theme` namespace and into daisyUI's semantic
slots, and it is ours to edit freely.

## Why `fonts.css` is not here

The upstream export ships a fourth file, `tokens/fonts.css`, whose whole body is
a remote `@import url('https://fonts.googleapis.com/...')`. Two reasons it does
not come along:

1. A nested remote `@import` inside a Tailwind entry is render-blocking and
   discovered late — the browser cannot start the font fetch until the CSS
   bundle has parsed.
2. Tailwind v4 inlines local `@import`s while bundling; a remote one is an edge
   case not worth relying on.

`index.html` loads the same three families (JetBrains Mono, Space Mono,
Silkscreen) with `preconnect` + a single stylesheet `<link>`, which is strictly
faster and states the dependency where a reader will look for it. The
`--font-mono` / `--font-display` / `--font-pixel` aliases that consume those
families still live in `typography.css`, unchanged.
