-- Live reload: writing a `.editorconfig` from inside the editor re-applies it to the
-- open buffers it covers, with no reload — including reverting a property the edit
-- stopped specifying.
--
-- Each assertion targets a bufnr captured when that file was opened, not a lookup by
-- name: buffers opened by earlier specs stay listed for the whole run, so a
-- name-based search could find one of those instead.

local ec = require("nxvim-editorconfig")
local fs = nx.fs

local function write(dir, name, content)
  local path = dir .. "/" .. name
  local parent = nx.utils.dirname(path)
  if parent ~= dir then
    nx.await(fs.mkdir(parent, { recursive = true }))
  end
  nx.await(fs.write(path, content))
  return path
end

-- `:edit path`, returning the bufnr it landed on.
local function edit(t, path)
  t:cmd("edit " .. path)
  return t:buf()
end

-- Poll until buffer `bufnr`'s option `opt` equals `value`.
local function expect_buf_opt(t, bufnr, opt, value)
  t:wait_for(function()
    return (nx.bo[bufnr][opt] == value) or nil
  end, {
    tries = 200,
    interval = 20,
    message = ("buffer %d: '%s' never became %s (it is %s)"):format(
      bufnr,
      opt,
      tostring(value),
      tostring(nx.bo[bufnr][opt])
    ),
  })
end

nx.test.describe("nxvim-editorconfig live reload", function()
  local ROOT

  nx.test.before_each(function()
    vim.g.editorconfig = true
    ec.setup({})
    -- Drop buffers tracked by earlier tests so a reused bufnr can't be re-resolved
    -- against a stale path from another tempdir.
    ec._files = {}
    ROOT = nx.test.tempdir()
  end)

  nx.test.it("re-applies an edited .editorconfig to the open buffer", function(t)
    write(ROOT, ".editorconfig", "root = true\n[*]\nindent_style = space\nindent_size = 2\n")
    local main = edit(t, write(ROOT, "main.txt", "hi\n"))
    expect_buf_opt(t, main, "shiftwidth", 2)

    edit(t, ROOT .. "/.editorconfig")
    t:cmd("%s/indent_size = 2/indent_size = 8/")
    t:cmd("write")

    expect_buf_opt(t, main, "shiftwidth", 8)
  end)

  nx.test.it("reverts a property the edit stopped specifying", function(t)
    write(ROOT, ".editorconfig", "root = true\n[*]\nindent_style = space\nindent_size = 2\n")
    local main = edit(t, write(ROOT, "main.txt", "hi\n"))
    expect_buf_opt(t, main, "expandtab", true)

    -- Drop indent_style, keep indent_size: expandtab is no longer dictated, so it
    -- goes back to what the buffer had before EditorConfig first touched it.
    edit(t, ROOT .. "/.editorconfig")
    t:cmd("g/^indent_style = space$/d")
    t:cmd("write")

    expect_buf_opt(t, main, "expandtab", false)
    nx.test.expect(nx.bo[main].shiftwidth).to_be(2)
  end)

  nx.test.it("only touches buffers the written config covers", function(t)
    write(ROOT, ".editorconfig", "root = true\n[*]\nindent_style = space\nindent_size = 2\n")
    write(ROOT, "sub/.editorconfig", "[*]\nindent_size = 3\n")
    local top = edit(t, write(ROOT, "top.txt", "hi\n"))
    local nested = edit(t, write(ROOT, "sub/nested.txt", "hi\n"))
    expect_buf_opt(t, nested, "shiftwidth", 3)

    edit(t, ROOT .. "/sub/.editorconfig")
    t:cmd("%s/indent_size = 3/indent_size = 9/")
    t:cmd("write")

    expect_buf_opt(t, nested, "shiftwidth", 9)
    nx.test.expect(nx.bo[top].shiftwidth).to_be(2)
  end)
end)
