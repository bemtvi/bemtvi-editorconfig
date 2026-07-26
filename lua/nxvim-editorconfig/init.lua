-- nxvim-editorconfig — `.editorconfig` support for nxvim, built entirely on the
-- native `nx.*` plugin API.
--
-- On every file-backed buffer read (`BufReadPost` / `BufNewFile`) it walks the
-- directory tree upward from the file, collects every `.editorconfig` along the way
-- (stopping at one that declares `root = true`), matches the file path against each
-- `[glob]` section, and applies the merged properties to the buffer's options. All
-- filesystem access goes through the async `nx.fs` seam (`nx.async` + `nx.await`)
-- so it never blocks the editor tick — local on a bare native build, the daemon's
-- filesystem leg over the wire otherwise, so it works on every front end including
-- the browser edit-host.
--
-- The resolution is also live: writing a `.editorconfig` from inside the editor
-- (`BufWritePost`) re-resolves — and re-applies — every open buffer it covers, with
-- no reload. A property the edit *stops* specifying reverts to the value the buffer
-- had before EditorConfig first touched it, so removing a rule undoes it instead of
-- leaving it stuck.
--
-- Toggle, mirroring neovim's editorconfig surface:
--   * `vim.g.editorconfig = false` disables it globally (default: on).
--   * `vim.b[bufnr].editorconfig = false` disables it for one buffer; a buffer's
--     explicit value (true/false) overrides the global one.
--
-- Properties honored (the ones that map to a real nxvim option — per the
-- EditorConfig spec, unrecognized/unsupported properties are simply ignored):
--
-- ```
-- indent_style  -> 'expandtab'                 (tab => off, space => on)
-- indent_size   -> 'shiftwidth'/'softtabstop'  (and 'tabstop' when tab_width unset)
-- tab_width     -> 'tabstop'
-- end_of_line   -> 'fileformat'                (lf=>unix, crlf=>dos, cr=>mac)
-- charset       -> 'fileencoding'              (+ 'bomb' for utf-8-bom)
-- ```
--
-- Plus the write-time pair, on `BufWritePre` (which in nxvim fires *before* the
-- buffer is serialized, so a mutation there is what reaches disk):
--   trim_trailing_whitespace -> strips trailing spaces/tabs (see `trim_trailing`)
--   insert_final_newline     -> `true` is free (the rope always keeps one trailing
--                               newline); `false` can't be expressed, and warns
--
-- `max_line_length` is resolved but not applied — nxvim has no `'textwidth'`. It, and
-- anything else in the file, is still exposed through
-- `require("nxvim-editorconfig").properties(bufnr)` for a config to act on.

local glob = require("nxvim-editorconfig.glob")
local parse = require("nxvim-editorconfig.parse")

local M = {}

-- Resolved property table per bufnr, exposed via `M.properties` (and the source for
-- anything acting on properties with no nxvim option).
M._resolved = {}
-- The absolute path each tracked buffer resolved from, so a written `.editorconfig`
-- can re-run the resolution without waiting for another BufReadPost.
M._files = {}
-- Per bufnr, the option values the buffer had *before* EditorConfig first touched
-- them, and the set of options the last application actually set. Together they let
-- a re-resolve revert an option a `.editorconfig` edit stopped specifying.
M._baseline = {}
M._applied = {}

-- ----- application -----------------------------------------------------------

-- Every buffer option EditorConfig properties can drive, in application order.
-- Explicit (rather than implied by whatever `derive` happened to return) because a
-- re-resolve has to *revert* the ones the new properties no longer dictate.
local MANAGED = {
  "expandtab",
  "tabstop",
  "shiftwidth",
  "softtabstop",
  "fileformat",
  "fileencoding",
  "bomb",
}

-- Map merged EditorConfig properties onto `{ <option> = <value> }`. An option the
-- properties don't dictate is simply absent from the result.
local function derive(props)
  local out = {}
  if props.indent_style == "tab" then
    out.expandtab = false
  elseif props.indent_style == "space" then
    out.expandtab = true
  end

  -- `indent_size = tab` means "follow tab_width"; otherwise it is numeric. When
  -- tab_width is unset it defaults to indent_size (EditorConfig spec).
  local indent_size = props.indent_size
  if indent_size == "tab" then
    indent_size = nil
  else
    indent_size = tonumber(indent_size)
  end
  local tab_width = tonumber(props.tab_width) or indent_size
  if tab_width and tab_width > 0 then
    out.tabstop = tab_width
  end
  if indent_size and indent_size > 0 then
    out.shiftwidth = indent_size
    out.softtabstop = indent_size
  end

  local eol = props.end_of_line
  if eol == "lf" then
    out.fileformat = "unix"
  elseif eol == "crlf" then
    out.fileformat = "dos"
  elseif eol == "cr" then
    out.fileformat = "mac"
  end

  local cs = props.charset
  if cs == "utf-8" or cs == "latin1" or cs == "utf-16le" or cs == "utf-16be" then
    out.fileencoding = cs
  elseif cs == "utf-8-bom" then
    out.fileencoding = "utf-8"
    out.bomb = true
  end
  return out
end

-- Apply merged EditorConfig properties to buffer `bufnr`'s options.
--
-- The first value written for an option records the buffer's pre-EditorConfig value
-- as that option's baseline, so a later resolution that no longer dictates it (the
-- rule was deleted from the `.editorconfig`, or a `root = true` moved) puts the
-- baseline back rather than leaving the stale value applied forever. Options this
-- plugin never set are never touched, so a manual `:setlocal` on one survives.
local function apply(bufnr, props)
  local want = derive(props)
  local baseline = M._baseline[bufnr] or {}
  M._baseline[bufnr] = baseline
  local previous = M._applied[bufnr] or {}
  local applied = {}
  for _, opt in ipairs(MANAGED) do
    local value = want[opt]
    if value ~= nil then
      if baseline[opt] == nil then
        baseline[opt] = nx.bo[bufnr][opt]
      end
      nx.bo[bufnr][opt] = value
      applied[opt] = true
    elseif previous[opt] and baseline[opt] ~= nil then
      nx.bo[bufnr][opt] = baseline[opt]
    end
  end
  M._applied[bufnr] = applied
end

-- ----- resolution ------------------------------------------------------------

-- Resolve the effective properties for `file` and apply them to `bufnr`. Walks the
-- tree upward collecting `.editorconfig` files (nearest first), stops at a
-- `root = true` one, then applies farthest-first so the nearest file wins; within a
-- file, later matching sections override earlier ones. Returns a promise.
M.resolve = nx.async(function(bufnr, file)
  -- A buffer's name is the path as typed, so it is routinely *relative*
  -- (`nxvim src/main.rs`, `:e sub/file.txt`). Resolve it against the editor's cwd up
  -- front: the walk below must reach the real project root, and the per-config `rel`
  -- below is computed by stripping an ancestor directory off this path, so the two
  -- must be the same (absolute) spelling.
  file = nx.fname.modify(file, ":p")
  M._files[bufnr] = file
  -- (dir, cfg) pairs, nearest directory first.
  local chain = {}
  for dir in nx.utils.ancestors(file) do
    local ok, text = pcall(nx.await, nx.fs.read_text(dir .. "/.editorconfig"))
    if ok and type(text) == "string" then
      local cfg = parse.parse(text)
      chain[#chain + 1] = { dir = dir, cfg = cfg }
      if cfg.root then
        break
      end
    end
  end

  -- Merge farthest-first (so nearer overrides), section order preserved.
  local props = {}
  for idx = #chain, 1, -1 do
    local entry = chain[idx]
    local rel = file:sub(#entry.dir + 2) -- strip "<dir>/"
    for _, sec in ipairs(entry.cfg.sections) do
      if glob.section_matches(sec.glob, rel) then
        for k, v in pairs(sec.props) do
          -- `unset` reverts a property to "unspecified".
          props[k] = (v ~= "unset") and v or nil
        end
      end
    end
  end

  M._resolved[bufnr] = props
  -- Unconditional even for an empty result: on a *re*-resolve an emptied config has
  -- to revert what the previous one applied (see `apply`), and with nothing ever
  -- applied it is a no-op anyway.
  apply(bufnr, props)
end)

-- Is EditorConfig active for this buffer? A buffer-local value wins over the global
-- one; both default to enabled.
local function enabled(bufnr)
  local b = vim.b[bufnr].editorconfig
  if b ~= nil then
    return b ~= false
  end
  if vim.g.editorconfig ~= nil then
    return vim.g.editorconfig ~= false
  end
  return true
end

-- ----- write-time transforms -------------------------------------------------

-- Strip trailing spaces/tabs from every line of `bufnr`. Called from `BufWritePre`,
-- which in nxvim runs *before* the buffer is serialized, so the trimmed text is what
-- lands on disk.
--
-- Deliberately NOT `nx.cmd([[%s/\s+$//]])`, which is both slower and wrong here: the
-- ex-command runs the regex engine over every line even when nothing matches (~170 ms
-- on a clean 20k-line buffer, versus ~4 ms for the scan below), moves the cursor,
-- clobbers the search register, and echoes `E486: Pattern not found` on every save of
-- an already-clean file — nxvim's `:s` has no `e` flag and no `silent!`.
--
-- Two things keep this cheap. The scan rejects a line in O(1): only a line whose LAST
-- byte is a space or tab can have trailing whitespace, so the (C-implemented) pattern
-- match runs solely on lines that actually need it — the steady state, a file with
-- nothing to trim, costs one `string.byte` per line and issues no edit at all. And the
-- rewrite is ONE `set_lines` spanning the first..last dirty line: each buffer mutation
-- is its own undo entry, so a per-line edit would cost the user one `u` per trimmed
-- line, while a single span keeps the whole trim undoable in one press.
local function trim_trailing(bufnr)
  if nx.bo[bufnr].modifiable == false then
    return
  end
  local lines = nx.buf.lines(bufnr, 0, -1, false)
  local first, last
  for i = 1, #lines do
    local tail = lines[i]:byte(-1)
    if tail == 32 or tail == 9 then -- " " or "\t" — vim's `\s`
      lines[i] = lines[i]:gsub("[ \t]+$", "")
      first = first or i
      last = i
    end
  end
  if not first then
    return
  end
  local slice = {}
  for i = first, last do
    slice[#slice + 1] = lines[i]
  end
  -- Queued, and applied right after this handler — before the write serializes.
  nx.buf.set_lines(bufnr, first - 1, last, false, slice)
end

-- Buffers already told that `insert_final_newline = false` can't be honored, so the
-- warning fires once per buffer rather than on every save.
local warned_final_newline = {}

-- `insert_final_newline` against nxvim's text model. The rope *always* keeps a single
-- trailing newline (the final phantom line is never edited or shown) and `:w` writes
-- the rope as-is, so every file nxvim saves already ends with one: `= true` is
-- satisfied with no work to do. `= false` would need the editor to drop that newline
-- on write — there is no `'endofline'`-style option to ask for it — so rather than
-- silently ignoring the setting, say so.
local function check_final_newline(bufnr, props)
  if props.insert_final_newline ~= "false" or warned_final_newline[bufnr] then
    return
  end
  warned_final_newline[bufnr] = true
  nx.notify(
    "nxvim-editorconfig: insert_final_newline = false is not supported — nxvim always "
      .. "writes a trailing newline",
    vim.log.levels.WARN
  )
end

-- Kick a resolution off and report a failure on the message line rather than
-- letting the rejection go unhandled.
local function run(bufnr, file)
  M.resolve(bufnr, file):catch(function(err)
    nx.notify("nxvim-editorconfig: " .. tostring(err), vim.log.levels.WARN)
  end)
end

-- ----- setup -----------------------------------------------------------------

-- `setup(opts)` — register the autocmds that drive everything. Called for you by
-- `plugin/nxvim-editorconfig.lua` when the plugin is on the runtimepath, so a user
-- only calls it to reconfigure. Re-running is safe: the augroup is cleared first.
--
-- `opts.enabled = false` registers nothing (the plugin stays inert for the session);
-- for a runtime toggle use `vim.g.editorconfig` / `vim.b[bufnr].editorconfig`, which
-- this plugin honors on every resolution.
function M.setup(opts)
  opts = opts or {}
  if vim.g.editorconfig == nil then
    vim.g.editorconfig = true
  end

  local grp = nx.augroup.create("nxvim-editorconfig")
  if opts.enabled == false then
    return M
  end

  local function on_open(ev)
    local bufnr = ev.buf
    local file = ev.file
    if type(file) ~= "string" or file == "" or not enabled(bufnr) then
      return
    end
    -- Fire-and-forget: the async chain settles over the next few ticks.
    run(bufnr, file)
  end

  nx.on("BufReadPost", { group = grp }, on_open)
  nx.on("BufNewFile", { group = grp }, on_open)

  -- The write-time transforms. `BufWritePre` fires BEFORE the buffer is serialized
  -- (and the write waits for an async handler), so a mutation here is what reaches
  -- disk. Only buffers this plugin has actually resolved are touched.
  nx.on("BufWritePre", { group = grp }, function(ev)
    local bufnr = ev.buf
    local props = M._resolved[bufnr]
    if not props or not enabled(bufnr) then
      return
    end
    if props.trim_trailing_whitespace == "true" then
      trim_trailing(bufnr)
    end
    check_final_newline(bufnr, props)
  end)

  -- Live reload: a written `.editorconfig` re-resolves every open buffer it covers —
  -- the ones under its directory — so an edit lands on them without a reload. Only a
  -- write *through the editor* is caught, which is the case that matters (you edited
  -- the project's rules); an outside change still applies on the next read.
  nx.on("BufWritePost", { group = grp }, function(ev)
    local file = ev.file
    if type(file) ~= "string" or nx.utils.basename(file) ~= ".editorconfig" then
      return
    end
    local dir = nx.utils.dirname(nx.fname.modify(file, ":p")) .. "/"
    for bufnr, path in pairs(M._files) do
      -- A `.editorconfig` only governs its own subtree, and a buffer that has gone
      -- away or opted out since it was resolved is left alone.
      if path:sub(1, #dir) == dir and nx.buf.is_loaded(bufnr) and enabled(bufnr) then
        run(bufnr, path)
      end
    end
  end)

  -- Drop a deleted buffer's tracked state (a reused bufnr should start clean).
  nx.on("BufDelete", { group = grp }, function(ev)
    local bufnr = ev.buf
    M._resolved[bufnr] = nil
    M._files[bufnr] = nil
    M._baseline[bufnr] = nil
    M._applied[bufnr] = nil
    warned_final_newline[bufnr] = nil
  end)

  return M
end

-- `properties(bufnr)` — the EditorConfig properties resolved for `bufnr` (defaults
-- to the current buffer), as a raw `{ key = value }` table — including ones with no
-- nxvim option (e.g. `trim_trailing_whitespace`, `max_line_length`) so a caller can
-- act on them. `nil` until the async resolution for that buffer has settled.
function M.properties(bufnr)
  if bufnr == nil or bufnr == 0 then
    bufnr = nx.buf.current()
  end
  return M._resolved[bufnr]
end

return M
