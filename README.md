# bemtvi-editorconfig

[EditorConfig](https://editorconfig.org) support for [bemtvi](https://github.com/davidrios/bemtvi),
built **entirely on the native `btv.*` plugin API** — nothing about `.editorconfig` lives in the
editor core.

Open a file and the plugin walks up from it, reads every `.editorconfig` on the way (stopping at
`root = true`), matches the path against each `[glob]` section, and applies the merged properties
to that buffer's options. Every filesystem read goes through the async `btv.fs` seam, so it never
blocks the editor tick and behaves the same locally, over a daemon, and in the browser.

It applies the indentation, line-ending and charset properties on open, and trims trailing
whitespace on write when the project asks for it. Edit a project's `.editorconfig` in the editor and
write it, and the new rules land on the open buffers straight away — no reload.

Async, but not a race: the resolution rides bemtvi's gated read chain, so `FileType` — and every
ftplugin, LSP attach and buffer-local mapping hanging off it — runs with the project's options
already applied.

## Install

Declare it with the built-in `:Plugins` manager and run `:PluginSync`. There is nothing to
configure:

```lua
btv.plugins({
  { "bemtvi/bemtvi-editorconfig" },
})
```

## Documentation

Full docs — every property and what it maps to, the resolution and glob rules, live reload, the
toggles, and the API — live in the help file. The same source renders
both on GitHub and in the editor:

- In editor: `:help bemtvi-editorconfig`
- On GitHub: [doc/bemtvi-editorconfig.md](./doc/bemtvi-editorconfig.md) (the help source)

## Development

Run the suite (a real editor, headless):

```sh
bemtvi --test-plugin .
```

The help file is generated — edit `doc/bemtvi-editorconfig.md`, never the `.txt`, then run
`bash scripts/gen-vimdoc.sh`. A pre-push hook guards against pushing a stale one; enable it once
after cloning:

```sh
pre-commit install --hook-type pre-push
```

## License

MIT
