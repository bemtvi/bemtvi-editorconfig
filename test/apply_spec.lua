-- End-to-end: lay out a project with `.editorconfig` files, open a file in it, and
-- assert on the buffer options the resolution applied. Run with
-- `nxvim --test-plugin`.
--
-- Application rides the async `nx.fs` seam, so a positive assertion polls
-- (`t:wait_for`); a negative one sleeps long enough for the chain to have run and
-- then asserts the default still holds.

local ec = require("nxvim-editorconfig")
local fs = nx.fs

local function join(dir, name)
  return dir .. "/" .. name
end

-- Write `dir/name`, creating the parent directory when the name is nested.
local function write(dir, name, content)
  local path = join(dir, name)
  local parent = nx.utils.dirname(path)
  if parent ~= dir then
    nx.await(fs.mkdir(parent, { recursive = true }))
  end
  nx.await(fs.write(path, content))
  return path
end

-- Poll until buffer option `opt` equals `value`, failing the test on timeout.
local function expect_opt(t, opt, value)
  t:wait_for(function()
    return (nx.bo[opt] == value) or nil
  end, {
    tries = 100,
    interval = 20,
    message = ("'%s' never became %s (it is %s)"):format(
      opt,
      tostring(value),
      tostring(nx.bo[opt])
    ),
  })
  nx.test.expect(nx.bo[opt]).to_be(value)
end

nx.test.describe("nxvim-editorconfig", function()
  local ROOT

  nx.test.before_each(function()
    vim.g.editorconfig = true
    ec.setup({})
    ROOT = nx.test.tempdir()
  end)

  nx.test.it("applies space indentation", function(t)
    write(ROOT, ".editorconfig", "root = true\n[*]\nindent_style = space\nindent_size = 2\n")
    local file = write(ROOT, "main.txt", "hello\n")
    t:cmd("edit " .. file)

    expect_opt(t, "shiftwidth", 2)
    nx.test.expect(nx.bo.expandtab).to_be(true)
    nx.test.expect(nx.bo.softtabstop).to_be(2)
    -- tab_width unset => tabstop follows indent_size.
    nx.test.expect(nx.bo.tabstop).to_be(2)
  end)

  nx.test.it("honors indent_style = tab with a distinct tab_width", function(t)
    write(
      ROOT,
      ".editorconfig",
      "root = true\n[*]\nindent_style = tab\nindent_size = 4\ntab_width = 8\n"
    )
    local file = write(ROOT, "main.txt", "hello\n")
    t:cmd("edit " .. file)

    expect_opt(t, "tabstop", 8)
    nx.test.expect(nx.bo.expandtab).to_be(false)
    nx.test.expect(nx.bo.shiftwidth).to_be(4)
  end)

  nx.test.it("selects the section by glob, nearest section winning", function(t)
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

  nx.test.it("maps end_of_line and charset onto fileformat / fileencoding", function(t)
    write(ROOT, ".editorconfig", "root = true\n[*]\nend_of_line = crlf\ncharset = latin1\n")
    local file = write(ROOT, "main.txt", "hello\n")
    t:cmd("edit " .. file)

    expect_opt(t, "fileformat", "dos")
    nx.test.expect(nx.bo.fileencoding).to_be("latin1")
  end)

  nx.test.it("treats property values as case-insensitive", function(t)
    write(
      ROOT,
      ".editorconfig",
      "root = true\n[*]\nindent_style = Space\nindent_size = 2\nend_of_line = CRLF\n"
    )
    local file = write(ROOT, "main.txt", "hi\n")
    t:cmd("edit " .. file)

    expect_opt(t, "fileformat", "dos")
    nx.test.expect(nx.bo.expandtab).to_be(true)
  end)

  nx.test.it("stops the upward search at a `root = true` config", function(t)
    -- The parent sets sw=2; the nested dir is `root = true` and sets nothing for
    -- this file, so the parent's `[*]` must NOT leak in.
    write(ROOT, ".editorconfig", "root = true\n[*]\nindent_style = space\nindent_size = 2\n")
    write(ROOT, "sub/.editorconfig", "root = true\n[*.md]\nindent_size = 9\n")
    local file = write(ROOT, "sub/main.txt", "hi\n")
    t:cmd("edit " .. file)

    t:sleep(200)
    nx.test.expect(nx.bo.shiftwidth).never.to_be(2)
  end)

  nx.test.it("lets the nearest config override the parent, inheriting the rest", function(t)
    write(ROOT, ".editorconfig", "root = true\n[*]\nindent_style = space\nindent_size = 2\n")
    write(ROOT, "sub/.editorconfig", "[*]\nindent_size = 8\n")
    local file = write(ROOT, "sub/main.txt", "hi\n")
    t:cmd("edit " .. file)

    expect_opt(t, "shiftwidth", 8)
    -- expandtab is inherited from the parent (the child set no indent_style).
    nx.test.expect(nx.bo.expandtab).to_be(true)
  end)

  nx.test.it("resolves a file opened by a relative path", function(t)
    -- The everyday case: `:cd project` then `:edit sub/main.txt`. The buffer's name
    -- is the relative path as typed, so the upward walk must resolve it against cwd.
    write(ROOT, ".editorconfig", "root = true\n[*]\nindent_style = space\nindent_size = 2\n")
    write(ROOT, "sub/main.txt", "hello\n")
    t:cmd("cd " .. ROOT)
    t:cmd("edit sub/main.txt")

    expect_opt(t, "shiftwidth", 2)
  end)

  nx.test.it("exposes the resolved properties, including unsupported ones", function(t)
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
    nx.test.expect(props.trim_trailing_whitespace).to_be("true")
  end)

  nx.test.it("is disabled by vim.g.editorconfig = false", function(t)
    write(ROOT, ".editorconfig", "root = true\n[*]\nindent_style = space\nindent_size = 2\n")
    local file = write(ROOT, "main.txt", "hi\n")
    vim.g.editorconfig = false
    t:cmd("edit " .. file)

    t:sleep(200)
    nx.test.expect(nx.bo.shiftwidth).never.to_be(2)
  end)

  nx.test.it("is disabled for one buffer by vim.b[buf].editorconfig = false", function(t)
    write(ROOT, ".editorconfig", "root = true\n[*]\nindent_style = space\nindent_size = 4\n")
    local file = write(ROOT, "main.txt", "hi\n")
    t:cmd("edit " .. file)
    expect_opt(t, "shiftwidth", 4)

    vim.b[t:buf()].editorconfig = false
    t:cmd("edit! " .. file) -- a reload resets the options, then skips EditorConfig
    t:sleep(200)
    nx.test.expect(nx.bo.shiftwidth).never.to_be(4)
  end)

  nx.test.it("re-enables one buffer with vim.b[buf].editorconfig = true", function(t)
    write(ROOT, ".editorconfig", "root = true\n[*]\nindent_style = space\nindent_size = 6\n")
    local file = write(ROOT, "main.txt", "hi\n")
    vim.g.editorconfig = false
    t:cmd("edit " .. file)
    t:sleep(200)
    nx.test.expect(nx.bo.shiftwidth).never.to_be(6)

    vim.b[t:buf()].editorconfig = true
    t:cmd("edit! " .. file)
    expect_opt(t, "shiftwidth", 6)
  end)
end)
