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

## Why the upstream `tokens/fonts.css` is not here

The upstream export ships a fourth file, `tokens/fonts.css`, whose whole body is
a remote `@import url('https://fonts.googleapis.com/...')`. It does not come
along, and neither does the `<link rel="stylesheet">` to Google Fonts that
replaced it for a while: **both load from a remote origin, and binnacle's CSP is
`style-src 'self'; font-src 'self'` with no remote origins.** A remote font
stylesheet is not slow here, it is blocked — see issue #61, where all three
families silently fell back to system fonts in production.

The three families (JetBrains Mono, Space Mono, Silkscreen) are therefore
**self-hosted**: WOFF2 files in `../../priv/static/fonts/`, declared as
`@font-face` in `../fonts.css`, which `app.css` imports. Latin and Latin-Ext
subsets only — the app is English-only.

Adding or changing a face means adding the WOFF2 **and** the `@font-face` block;
`test/binnacle_web/plugs/security_headers_test.exs` fetches every URL `fonts.css`
declares and fails if one 404s. The `--font-mono` / `--font-display` /
`--font-pixel` aliases that consume these families still live in
`typography.css`, unchanged.

Do not reintroduce a remote font `@import` or `<link>`. It will be blocked.
