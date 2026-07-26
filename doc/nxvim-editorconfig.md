<!-- DO NOT EDIT doc/nxvim-editorconfig.txt BY HAND. It is generated from this file by
panvimdoc — run `scripts/gen-vimdoc.sh` after editing. -->

EditorConfig support for nxvim, built entirely on the native `nx.*` plugin API — nothing about
`.editorconfig` lives in the editor core.

Open a file and the plugin walks the directory tree upward from it, reads every `.editorconfig`
along the way (stopping at one that declares `root = true`), matches the path against each
`[glob]` section, and applies the merged properties to that buffer's options. Every filesystem
read goes through the async `nx.fs` seam, so it never blocks the editor tick and works the same
locally, over a daemon, and in the browser.

Editing a project's `.editorconfig` in the editor and writing it re-applies the new rules to the
open buffers straight away — no reload.

<!-- Passed through verbatim so `:help nxvim-editorconfig` lands on this page
     (panvimdoc derives per-section tags but no bare project tag). -->
```vimdoc
                                                          *nxvim-editorconfig*
```

# Install

Put the repo on your `runtimepath` — with `nx.plugins`, or any plugin manager.
`plugin/nxvim-editorconfig.lua` auto-sources on load and registers everything with defaults, so
there is nothing to configure:

```lua
nx.plugins({
  { "nxvim/nxvim-editorconfig" },
})
```

Run `:PluginSync` to clone it. That is the whole setup — open a file in a project that has a
`.editorconfig` and its rules are in effect.

# Properties

These EditorConfig properties map onto a real nxvim option and are applied:

```
indent_style              ->  'expandtab'                  tab => off, space => on
indent_size               ->  'shiftwidth' + 'softtabstop' (and 'tabstop' when tab_width is unset)
tab_width                 ->  'tabstop'
end_of_line               ->  'fileformat'                 lf => unix, crlf => dos, cr => mac
charset                   ->  'fileencoding'               (+ 'bomb' for utf-8-bom)
trim_trailing_whitespace  ->  strips trailing spaces/tabs on write
insert_final_newline      ->  always satisfied (see below)
```

`indent_size = tab` means "follow `tab_width`". An `indent_size` with no `tab_width` also sets
`'tabstop'`, per the spec. A property set to `unset` reverts to unspecified.

`trim_trailing_whitespace = true` runs on `BufWritePre`, which in nxvim fires *before* the buffer
is serialized, so the trimmed text is what reaches disk. It is one edit spanning the first to the
last changed line, so the whole trim undoes in a single `u`.

`insert_final_newline` needs no work to satisfy in the `true` direction: nxvim's rope always keeps
one trailing newline, and `:w` writes the rope as-is, so a saved file always ends with exactly one.
Setting it to `false` asks for the opposite, which nxvim cannot express (there is no
`'endofline'`-style option) — so instead of ignoring it, the plugin warns once per buffer.

`max_line_length` is resolved but not applied: nxvim has no `'textwidth'`. Per the EditorConfig
spec, any property that is not recognized at all is simply ignored. Everything resolved — applied
or not — is readable through `properties()` below, so a config can act on it itself:

```lua
local props = require("nxvim-editorconfig").properties(0)
if props and props.max_line_length then
  nx.wo.colorcolumn = props.max_line_length   -- 'colorcolumn' is window-local
end
```

# Resolution

The rules follow the EditorConfig specification:

- The search walks up from the file's directory and stops at the first `.editorconfig` whose
  preamble says `root = true`.
- Files are merged **farthest first**, so the nearest `.editorconfig` wins on a conflict; within
  one file, a later matching `[section]` overrides an earlier one.
- A section header with no `/` matches the **basename** at any depth (`[*.py]` matches
  `deep/nested/app.py`). A leading `/` anchors to the config's own directory. Any other `/` makes
  the glob relative to that directory.
- Glob syntax: `*` (any run not crossing `/`), `**` (any run including `/`), `?` (one character),
  `[abc]` / `[a-c]` / `[!abc]` classes, `{a,b}` alternation, and `{1..9}` numeric ranges.

A buffer opened by a relative path (`nxvim src/main.rs`, `:e sub/file.txt`) is resolved against the
editor's working directory first, so the walk still reaches the project root.

Only ordinary file buffers are resolved. A scratch surface — help, a terminal, quickfix, an
`nx.view` dock — is skipped on its `'buftype'`, so EditorConfig never sets `'expandtab'` on a
listing you cannot edit.

# Ordering

The resolution is async, but it is not a race. nxvim's read lifecycle is a **gated chain** —
`BufReadPost` → *settle* → `FileType` → `BufEnter` → `BufWinEnter` — and this plugin's read handler
returns its promise into it. So by the time `FileType` fires, the EditorConfig options are already
applied, and everything hanging off `FileType` (an ftplugin-style handler, an LSP attach, a
buffer-local mapping) reads the project's values rather than the defaults:

```lua
nx.on("FileType", {}, function(args)
  -- Already the .editorconfig value, not the default it would otherwise have raced.
  print(nx.bo[args.buf].shiftwidth)
end)
```

The editor waits up to its settle budget (500 ms) for this. The walk reads every directory level
**concurrently** rather than one round trip per level, so a deeply nested file over a daemon still
resolves in a single round trip and the budget is not the binding constraint. If a filesystem is
slow enough to blow it anyway, the chain advances without waiting further and the options are
applied when the read lands — late, never dropped.

# Live reload

Writing a `.editorconfig` from inside the editor re-resolves — and re-applies — every open buffer
that the written file governs (the ones under its directory). So this takes effect immediately:

```
:e .editorconfig       " change indent_size = 4 to 2
:w
```

Buffers under that directory pick the change up with no `:e!` and no restart.

A property the edit **stops** specifying reverts to the value the buffer had before the plugin
first touched it, so deleting a rule undoes it instead of leaving the old value stuck. Options the
plugin never set are never touched, so a manual `:setlocal` on one survives.

Only writes *through the editor* are caught — that is the case that matters, since you edited the
project's rules. A change made outside the editor (a `git checkout`, another editor) applies the
next time the file is read.

# Toggles

The same surface neovim's built-in editorconfig exposes:

```lua
vim.g.editorconfig = false          -- off globally (default: on)
vim.b.editorconfig = false          -- off for the current buffer
vim.b[bufnr].editorconfig = false   -- ...or a specific one
```

A buffer's explicit value wins over the global one. Both are read on every resolution, so flipping
either takes effect from the next resolution onward — for a buffer already open, `:e!` to re-fire
it.

Opting one filetype out while leaving the rest on:

```lua
nx.on("FileType", {}, function(args)
  if args.match == "markdown" then
    -- Prose: let your own settings win, not the project's .editorconfig.
    vim.b[args.buf].editorconfig = false
  end
end)
```

That works even though `FileType` runs a stage *after* the resolution (see
[Ordering](#ordering)): the plugin reads the flag once more at the end of the read chain and puts
back what it applied. Only the options it set are reverted, so a `:setlocal` of your own survives.

`setup({ enabled = false })` is the load-time equivalent: it registers no autocmds at all, leaving
the plugin inert for the session.

# API

## setup

`require("nxvim-editorconfig").setup(opts)`

Registers the autocmds that drive everything. `plugin/nxvim-editorconfig.lua` calls it for you when
the plugin loads, so you only call it to reconfigure. Re-running is safe — the augroup is cleared
first. `opts.enabled = false` registers nothing.

## properties

`require("nxvim-editorconfig").properties(bufnr)`

The EditorConfig properties resolved for `bufnr` (`0` or omitted = the current buffer), as a raw
`{ key = value }` table with every value a string — including properties the plugin does not act
on, so you can act on them yourself. Returns `nil` until the buffer's (async) resolution has
settled.

## resolve

`require("nxvim-editorconfig").resolve(bufnr, file)`

Resolve `file` and apply it to `bufnr`, returning a promise that fulfils when the options are set.
The autocmds call this; you only need it to force a resolution by hand.

# How it works

Everything is public `nx.*`, and worth reading if you are writing a plugin:

- `nx.on` / `nx.augroup` — `BufReadPost` / `BufNewFile` drive the first resolution, `BufWinEnter`
  the late opt-out check, `BufWritePre` the trim, `BufWritePost` the live reload, `BufDelete` the
  cleanup. The read handler **returns**
  its promise, which is what orders the rest of the read chain behind it (see
  [Ordering](#ordering)); the live-reload handler is narrowed by the autocmd `pattern`
  `**/.editorconfig`, which matches that basename at any depth — absolute or relative — without
  matching `foo.editorconfig`.
- `nx.fs.read_text` inside `nx.async` / `nx.await`, fanned out with `nx.promise.all_settled` — every
  directory level is read at once rather than one await per level, so the walk is one round trip
  deep however deep the file is. A slow or remote filesystem never stalls a keystroke either way.
- `nx.utils.ancestors` / `nx.fname.modify` — the upward directory walk and the relative→absolute
  resolution behind it.
- `nx.bo[bufnr]` — the buffer options the properties map onto, and `'buftype'` as the canonical
  "is this a real file" signal.
- `nx.buf.lines` / `nx.buf.set_lines` — the trim reads the buffer mirror, rejects a line in O(1)
  (only a line whose last byte is a space or tab can have trailing whitespace, so the pattern match
  runs solely on lines that need it), and issues at most ONE edit. The obvious
  `nx.cmd([[%s/\s+$//]])` is 2–12x slower on the same buffer — it runs the regex engine over every
  line even when nothing matches — moves the cursor, clobbers the search register, and echoes
  `E486: Pattern not found` on every save of an already-clean file, since nxvim's `:s` has no `e`
  flag. (`nx.cmd(cmd, { emsg_silent = true })` would silence that last one, and none of the rest.)

The parser (`nxvim-editorconfig.parse`) turns one file into its `root` flag plus its sections in
file order. The glob dialect is the plugin's own (`nxvim-editorconfig.glob`): brace expansion into
plain globs, then a backtracking matcher. That is deliberate, not an oversight — nxvim ships one
glob engine in `nx.glob`, but EditorConfig's dialect differs from it in two ways that matter:
`**` crosses `/` **anywhere** (so `[**.js]` matches `a/b/c.js`, where `nx.glob` treats `**` as
recursive only when it is a whole path component), and `{1..9}` is a numeric range, which `nx.glob`
has no notion of. Both divergences are pinned as tests in `test/glob_spec.lua`, so if the core ever
grows the dialect, those tests fail and this module can go.

# Tests

The suite runs a real editor headlessly:

```sh
nxvim --test-plugin .
```

The help file is generated from `doc/nxvim-editorconfig.md` by `scripts/gen-vimdoc.sh`; a pre-push
hook (`pre-commit install --hook-type pre-push`) fails if the committed `.txt` is stale.

`test/glob_spec.lua` and `test/parse_spec.lua` cover the dialect and the parser directly;
`test/apply_spec.lua` lays out real projects in a temp directory, opens files in them, and asserts
on the resulting buffer options; `test/live_spec.lua` covers the write-driven reload and the revert; `test/write_spec.lua`
asserts the trim on the bytes that reach disk.
