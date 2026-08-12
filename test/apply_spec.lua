-- End-to-end: lay out a project with `.editorconfig` files, open a file in it, and
-- assert on the buffer options the resolution applied. Run with
-- `bemtvi --test-plugin`.
--
-- Application rides the async `btv.fs` seam, so a positive assertion polls
-- (`t:wait_for`); a negative one sleeps long enough for the chain to have run and
-- then asserts the default still holds.

local ec = require("bemtvi-editorconfig")
local fs = btv.fs

local function join(dir, name)
  return dir .. "/" .. name
end

-- Write `dir/name`, creating the parent directory when the name is nested.
local function write(dir, name, content)
  local path = join(dir, name)
  local parent = btv.utils.dirname(path)
  if parent ~= dir then
    btv.await(fs.mkdir(parent, { recursive = true }))
  end
  btv.await(fs.write(path, content))
  return path
end

-- Poll until buffer option `opt` equals `value`, failing the test on timeout.
local function expect_opt(t, opt, value)
  t:wait_for(function()
    return (btv.bo[opt] == value) or nil
  end, {
    tries = 100,
    interval = 20,
    message = ("'%s' never became %s (it is %s)"):format(
      opt,
      tostring(value),
      tostring(btv.bo[opt])
    ),
  })
  btv.test.expect(btv.bo[opt]).to_be(value)
end

btv.test.describe("bemtvi-editorconfig", function()
  local ROOT

  btv.test.before_each(function()
    vim.g.editorconfig = true
    ec.setup({})
    ROOT = btv.test.tempdir()
  end)

  btv.test.it("applies space indentation", function(t)
    write(ROOT, ".editorconfig", "root = true\n[*]\nindent_style = space\nindent_size = 2\n")
    local file = write(ROOT, "main.txt", "hello\n")
    t:cmd("edit " .. file)

    expect_opt(t, "shiftwidth", 2)
    btv.test.expect(btv.bo.expandtab).to_be(true)
    btv.test.expect(btv.bo.softtabstop).to_be(2)
    -- tab_width unset => tabstop follows indent_size.
    btv.test.expect(btv.bo.tabstop).to_be(2)
  end)

  btv.test.it("honors indent_style = tab with a distinct tab_width", function(t)
    write(
      ROOT,
      ".editorconfig",
      "root = true\n[*]\nindent_style = tab\nindent_size = 4\ntab_width = 8\n"
    )
    local file = write(ROOT, "main.txt", "hello\n")
    t:cmd("edit " .. file)

    expect_opt(t, "tabstop", 8)
    btv.test.expect(btv.bo.expandtab).to_be(false)
    btv.test.expect(btv.bo.shiftwidth).to_be(4)
  end)

  btv.test.it("selects the section by glob, nearest section winning", function(t)
    write(
      ROOT,
      ".editorconfig",
      "root = true\n"
        .. "[*]\nindent_size = 3\n"
        .. "[*.py]\nindent_style = space\nindent_size = 4\n"
        .. "[*.{js,ts}]\nindent_style = space\nindent_size = 2\n"
    )
    local py = write(ROOT, "a.py", "x\n")
    local ts = write(ROOT, "a.ts", "x\n")

    t:cmd("edit " .. py)
    expect_opt(t, "shiftwidth", 4)

    t:cmd("edit " .. ts)
    expect_opt(t, "shiftwidth", 2)
  end)

  btv.test.it("maps end_of_line and charset onto fileformat / fileencoding", function(t)
    write(ROOT, ".editorconfig", "root = true\n[*]\nend_of_line = crlf\ncharset = latin1\n")
    local file = write(ROOT, "main.txt", "hello\n")
    t:cmd("edit " .. file)

    expect_opt(t, "fileformat", "dos")
    btv.test.expect(btv.bo.fileencoding).to_be("latin1")
  end)

  btv.test.it("treats property values as case-insensitive", function(t)
    write(
      ROOT,
      ".editorconfig",
      "root = true\n[*]\nindent_style = Space\nindent_size = 2\nend_of_line = CRLF\n"
    )
    local file = write(ROOT, "main.txt", "hi\n")
    t:cmd("edit " .. file)

    expect_opt(t, "fileformat", "dos")
    btv.test.expect(btv.bo.expandtab).to_be(true)
  end)

  btv.test.it("stops the upward search at a `root = true` config", function(t)
    -- The parent sets sw=2; the nested dir is `root = true` and sets nothing for
    -- this file, so the parent's `[*]` must NOT leak in.
    write(ROOT, ".editorconfig", "root = true\n[*]\nindent_style = space\nindent_size = 2\n")
    write(ROOT, "sub/.editorconfig", "root = true\n[*.md]\nindent_size = 9\n")
    local file = write(ROOT, "sub/main.txt", "hi\n")
    t:cmd("edit " .. file)

    t:sleep(200)
    btv.test.expect(btv.bo.shiftwidth).never.to_be(2)
  end)

  btv.test.it("lets the nearest config override the parent, inheriting the rest", function(t)
    write(ROOT, ".editorconfig", "root = true\n[*]\nindent_style = space\nindent_size = 2\n")
    write(ROOT, "sub/.editorconfig", "[*]\nindent_size = 8\n")
    local file = write(ROOT, "sub/main.txt", "hi\n")
    t:cmd("edit " .. file)

    expect_opt(t, "shiftwidth", 8)
    -- expandtab is inherited from the parent (the child set no indent_style).
    btv.test.expect(btv.bo.expandtab).to_be(true)
  end)

  btv.test.it("resolves a file opened by a relative path", function(t)
    -- The everyday case: `:cd project` then `:edit sub/main.txt`. The buffer's name
    -- is the relative path as typed, so the upward walk must resolve it against cwd.
    write(ROOT, ".editorconfig", "root = true\n[*]\nindent_style = space\nindent_size = 2\n")
    write(ROOT, "sub/main.txt", "hello\n")
    t:cmd("cd " .. ROOT)
    t:cmd("edit sub/main.txt")

    expect_opt(t, "shiftwidth", 2)
  end)

  btv.test.it("exposes the resolved properties, including unsupported ones", function(t)
    write(
      ROOT,
      ".editorconfig",
      "root = true\n[*]\nindent_size = 2\ntrim_trailing_whitespace = true\n"
    )
    local file = write(ROOT, "main.txt", "hi\n")
    t:cmd("edit " .. file)

    local props = t:wait_for(function()
      local p = ec.properties(0)
      return (p and p.indent_size == "2") and p or nil
    end, { tries = 100, interval = 20, message = "properties never resolved" })
    btv.test.expect(props.trim_trailing_whitespace).to_be("true")
  end)

  btv.test.it("is disabled by vim.g.editorconfig = false", function(t)
    write(ROOT, ".editorconfig", "root = true\n[*]\nindent_style = space\nindent_size = 2\n")
    local file = write(ROOT, "main.txt", "hi\n")
    vim.g.editorconfig = false
    t:cmd("edit " .. file)

    t:sleep(200)
    btv.test.expect(btv.bo.shiftwidth).never.to_be(2)
  end)

  btv.test.it("is disabled for one buffer by vim.b[buf].editorconfig = false", function(t)
    write(ROOT, ".editorconfig", "root = true\n[*]\nindent_style = space\nindent_size = 4\n")
    local file = write(ROOT, "main.txt", "hi\n")
    t:cmd("edit " .. file)
    expect_opt(t, "shiftwidth", 4)

    vim.b[t:buf()].editorconfig = false
    t:cmd("edit! " .. file) -- a reload resets the options, then skips EditorConfig
    t:sleep(200)
    btv.test.expect(btv.bo.shiftwidth).never.to_be(4)
  end)

  btv.test.it("re-enables one buffer with vim.b[buf].editorconfig = true", function(t)
    write(ROOT, ".editorconfig", "root = true\n[*]\nindent_style = space\nindent_size = 6\n")
    local file = write(ROOT, "main.txt", "hi\n")
    vim.g.editorconfig = false
    t:cmd("edit " .. file)
    t:sleep(200)
    btv.test.expect(btv.bo.shiftwidth).never.to_be(6)

    vim.b[t:buf()].editorconfig = true
    t:cmd("edit! " .. file)
    expect_opt(t, "shiftwidth", 6)
  end)

  -- The read chain is gated: `BufReadPost` -> settle -> `FileType`. Because the read
  -- handler RETURNS its promise, a `FileType` handler — where ftplugins, LSP attach
  -- and buffer-local maps live — sees the EditorConfig options already applied rather
  -- than the defaults it would have raced. Drop the `return` in `on_open` and this
  -- fails, which is the point of asserting it.
  btv.test.it("has applied the options before FileType runs", function(t)
    write(ROOT, ".editorconfig", "root = true\n[*]\nindent_style = space\nindent_size = 3\n")
    local file = write(ROOT, "seen.lua", "return {}\n")

    local seen
    local id = btv.on("FileType", { pattern = "lua" }, function(ev)
      -- First announce only: FileType also fires on a later `:set ft=`, and the
      -- first observation is the one the ordering claim is about.
      if seen == nil and btv.buf.name(ev.buf) ~= "" then
        seen = { shiftwidth = btv.bo[ev.buf].shiftwidth, expandtab = btv.bo[ev.buf].expandtab }
      end
    end)

    t:cmd("edit " .. file)
    t:wait_for(function()
      return seen
    end, { tries = 200, interval = 20, message = "FileType never fired for the buffer" })
    btv.off(id)

    btv.test.expect(seen.shiftwidth).to_be(3)
    btv.test.expect(seen.expandtab).to_be(true)
  end)

  -- The documented way to opt one filetype out is a `FileType` handler flipping
  -- `vim.b[buf].editorconfig`. That runs a whole stage AFTER the resolution, so the
  -- flag can only work if the plugin re-reads it at the end of the read chain and
  -- puts back what it applied.
  btv.test.it("honors an opt-out set from a FileType handler", function(t)
    write(ROOT, ".editorconfig", "root = true\n[*]\nindent_style = space\nindent_size = 5\n")
    local file = write(ROOT, "optout.lua", "return {}\n")

    local id = btv.on("FileType", { pattern = "lua" }, function(ev)
      vim.b[ev.buf].editorconfig = false
    end)
    t:cmd("edit " .. file)
    t:sleep(300)
    btv.off(id)

    btv.test.expect(btv.bo.shiftwidth).never.to_be(5)
    btv.test.expect(btv.bo.expandtab).to_be(false)
    vim.b[t:buf()].editorconfig = nil
  end)

  -- `'buftype'` is the canonical "is this a real file" signal, and the gate matters
  -- more now that the read chain waits on us: a scratch surface must not park
  -- `FileType` behind a filesystem walk (nor have `'expandtab'` set on it).
  btv.test.it("ignores a buffer that is not an ordinary file", function(t)
    write(ROOT, ".editorconfig", "root = true\n[*]\nindent_style = space\nindent_size = 7\n")

    -- The quickfix window is a real non-file surface the core models (`'buftype'` is
    -- `quickfix`), and it has a name, so the skip below can only come from the buftype
    -- gate and not from the "no file name" arm above it.
    t:cmd("cd " .. ROOT)
    t:cmd("copen")
    local buf = t:buf()
    btv.test.expect(btv.bo[buf].buftype).to_be("quickfix")
    ec._files[buf] = nil -- an earlier spec may have tracked this bufnr
    btv.autocmd.exec("BufReadPost", { buffer = buf })

    t:sleep(200)
    btv.test.expect(ec._files[buf]).to_be(nil)
    btv.test.expect(btv.bo[buf].shiftwidth).never.to_be(7)
    t:cmd("cclose")
  end)
end)
