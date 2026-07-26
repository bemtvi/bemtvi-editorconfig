-- Runnable example for nxvim-editorconfig.
--
--   NXVIM_CONFIG=examples nxvim examples/app.py
--
-- Each section has a *type-this / see-that* note.

-- Load the plugin straight from this repo (a local-dev spec: `dir` is never cloned, and
-- adding it to the runtimepath is what makes `require("nxvim-editorconfig")` resolve and
-- auto-sources `plugin/`, which calls `setup({})`). A real config would instead use
-- `{ "nxvim/nxvim-editorconfig" }` + :PluginSync — there is nothing to configure.
nx.plugins({
  {
    name = "nxvim-editorconfig",
    dir = vim.fn.expand("<sfile>:p:h:h"), -- the repo root (this file's grandparent dir)
  },
})

-- On open, the plugin walks up from the file, reads every `.editorconfig` (stopping
-- at one with `root = true`), matches the path against each `[glob]` section, and
-- applies the merged properties to the buffer's options:
--
--     indent_style -> expandtab        indent_size -> shiftwidth / softtabstop
--     tab_width    -> tabstop          end_of_line -> fileformat (lf/crlf/cr)
--     charset      -> fileencoding (+ bomb for utf-8-bom)
--
-- and on write (BufWritePre, before the bytes are serialized):
--
--     trim_trailing_whitespace -> strips trailing spaces/tabs from every line
--
-- The `.editorconfig` next to this file gives `app.py` 4-space indent, `mod.lua`
-- 2-space indent, and `Makefile` real 8-wide tabs — all from one project file.

-- 1. The toggles, exactly like neovim:
--
--      vim.g.editorconfig = false           -- off globally (default: true)
--      vim.b.editorconfig = false           -- off for the current buffer
--      vim.b[bufnr].editorconfig = false    -- ...or a specific buffer
--
--    A buffer's explicit value wins over the global one. For example, opt one
--    filetype out while leaving the rest on:
--
--    This works even though `FileType` runs a stage AFTER the resolution: nxvim's
--    read chain is gated (BufReadPost -> settle -> FileType -> BufEnter ->
--    BufWinEnter), and the plugin re-reads the flag at the end of it, reverting what
--    it applied. Which is also why the print below already sees the project's value.
nx.on("FileType", {}, function(args)
  if args.match == "markdown" then
    -- Prose: let your own settings win, not the project's .editorconfig.
    vim.b[args.buf].editorconfig = false
  end
end)

-- 1b. The ordering guarantee, made visible: this runs on FileType, one stage behind
--     the resolution, so `shiftwidth` is already the .editorconfig value rather than
--     the default it would otherwise have raced.
nx.on("FileType", {}, function(args)
  nx.notify(
    ("FileType %s: shiftwidth is already %d"):format(args.match, nx.bo[args.buf].shiftwidth)
  )
end)

-- 2. Inspect the resolved properties for a buffer (handy for debugging a project's
--    rules, and the way to reach properties with no nxvim option, e.g.
--    trim_trailing_whitespace / max_line_length):
nx.command("EditorConfigShow", function()
  local props = require("nxvim-editorconfig").properties(0)
  if not props then
    nx.notify("no .editorconfig resolved for this buffer")
    return
  end
  local parts = {}
  for k, v in pairs(props) do
    parts[#parts + 1] = k .. " = " .. tostring(v)
  end
  table.sort(parts)
  nx.notify("editorconfig: " .. table.concat(parts, ", "))
end)

--------------------------------------------------------------------------------
-- Try it:
--
-- 1. Open `app.py` (matches `[*]`): `i<Tab>x<Esc>` inserts FOUR spaces.
--    Run `:EditorConfigShow` -> indent_size = 4, indent_style = space, ...
--
-- 2. Open `mod.lua` (`:e examples/mod.lua`): the `[*.lua]` section narrows
--    indent_size to 2, so `i<Tab>x<Esc>` inserts TWO spaces.
--
-- 3. Open `Makefile` (`:e examples/Makefile`): `[{Makefile,*.mk}]` sets real tabs
--    8 cells wide -> `i<Tab>x<Esc>` inserts a literal "\t".
--
-- 4. Toggle it off and reload to see the defaults come back:
--      :lua vim.g.editorconfig = false
--      :e! examples/app.py                  -> indent is no longer forced.
--
-- 5. Live reload — with `app.py` open, edit the project's `.editorconfig` from
--    inside the editor itself:
--      :e examples/.editorconfig            -> change `indent_size = 4` to `2`
--      :w
--      :e#                                  -> back to app.py
--    `i<Tab>x<Esc>` now inserts TWO spaces and `:EditorConfigShow` reports the new
--    value — the open buffer picked the edit up with no reload. Delete the
--    `indent_style = space` line the same way and `:set expandtab?` reverts to the
--    `noexpandtab` the buffer had before EditorConfig ever touched it.
--
-- 6. Ordering: every one of those opens echoes
--      FileType python: shiftwidth is already 4
--    from the handler in section 1b — the project's value, not the default, because
--    the read chain waits for the resolution before firing `FileType`.
--
-- 7. Per-filetype opt-out: `:e examples/notes.md` -> `i<Tab>x<Esc>` does NOT insert
--    the project's four spaces, because section 1 flipped
--    `vim.b[buf].editorconfig = false` for markdown. Note the echo from 1b still says
--    `shiftwidth is already 4` — at `FileType` it was; the opt-out set there is
--    honored one stage later, at `BufWinEnter`, which puts the option back.
--    `:EditorConfigShow` still lists the properties (they did resolve); they are just
--    no longer applied to this buffer.
--
-- 8. Trim-on-save: `app.py` has `trim_trailing_whitespace = true`. Type
--    `Gotrailing   <Esc>` (a new last line ending in spaces), `:w`, then reopen with
--    `:e!` -> the spaces are gone from the saved file. The whole trim is ONE undo
--    step, so a single `u` right after the write brings them back.
--------------------------------------------------------------------------------
