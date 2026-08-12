-- The write-time transforms: `trim_trailing_whitespace` (and what
-- `insert_final_newline` can and cannot do here).
--
-- Every assertion is on the BYTES ON DISK, not the buffer: the point of running in
-- `BufWritePre` is that the mutation reaches the saved file.

local ec = require("bemtvi-editorconfig")
local fs = btv.fs

local function write(dir, name, content)
  local path = dir .. "/" .. name
  btv.await(fs.write(path, content))
  return path
end

-- Poll the file until it satisfies `pred`, returning its contents.
local function on_disk(t, path, pred, message)
  return t:wait_for(function()
    local ok, text = pcall(btv.await, fs.read_text(path))
    return (ok and pred(text) and text) or nil
  end, { tries = 150, interval = 20, message = message })
end

-- Open `path` and wait for its EditorConfig properties to settle (the transforms
-- only run for a buffer that has been resolved).
local function open_resolved(t, path)
  t:cmd("edit " .. path)
  t:wait_for(function()
    return ec.properties(0) or nil
  end, { tries = 100, interval = 20, message = "properties never resolved for " .. path })
  return t:buf()
end

btv.test.describe("bemtvi-editorconfig write transforms", function()
  local ROOT

  btv.test.before_each(function()
    vim.g.editorconfig = true
    ec.setup({})
    ec._files = {}
    ROOT = btv.test.tempdir()
  end)

  btv.test.it("trims trailing spaces and tabs from what lands on disk", function(t)
    write(ROOT, ".editorconfig", "root = true\n[*]\ntrim_trailing_whitespace = true\n")
    local file = write(ROOT, "f.txt", "alpha   \nbeta\t\t\ngamma\n")
    open_resolved(t, file)
    t:feed("GA!<Esc>") -- modify the buffer so the write has something to do

    t:cmd("write")
    local text = on_disk(t, file, function(s)
      return s:find("!", 1, true) ~= nil
    end, "the write never landed")
    btv.test.expect(text).to_be("alpha\nbeta\ngamma!\n")
  end)

  btv.test.it("leaves interior whitespace and blank lines alone", function(t)
    write(ROOT, ".editorconfig", "root = true\n[*]\ntrim_trailing_whitespace = true\n")
    local file = write(ROOT, "f.txt", "a\tb  c   \n\n   \nend\n")
    open_resolved(t, file)
    t:feed("GA!<Esc>")

    t:cmd("write")
    local text = on_disk(t, file, function(s)
      return s:find("!", 1, true) ~= nil
    end, "the write never landed")
    -- Only the trailing runs go; the tab and double space INSIDE line 1 stay, and a
    -- whitespace-only line becomes empty rather than disappearing.
    btv.test.expect(text).to_be("a\tb  c\n\n\nend!\n")
  end)

  btv.test.it("does not trim unless the property asks for it", function(t)
    write(ROOT, ".editorconfig", "root = true\n[*]\nindent_size = 2\n")
    local file = write(ROOT, "f.txt", "alpha   \n")
    open_resolved(t, file)
    t:feed("GA!<Esc>")

    t:cmd("write")
    local text = on_disk(t, file, function(s)
      return s:find("!", 1, true) ~= nil
    end, "the write never landed")
    btv.test.expect(text).to_be("alpha   !\n")
  end)

  btv.test.it("says nothing on the message line when there is nothing to trim", function(t)
    -- The reason this isn't `:%s/\s+$//`: a clean file would echo E486 on every save.
    write(ROOT, ".editorconfig", "root = true\n[*]\ntrim_trailing_whitespace = true\n")
    local file = write(ROOT, "f.txt", "alpha\nbeta\n")
    open_resolved(t, file)
    t:feed("GA!<Esc>")

    t:cmd("write")
    on_disk(t, file, function(s)
      return s:find("!", 1, true) ~= nil
    end, "the write never landed")
    btv.test.expect(t:message():find("E486")).to_be(nil)
  end)

  btv.test.it("undoes the whole trim in one press", function(t)
    -- The trim is ONE `set_lines` over the dirty span precisely so that a save
    -- costs the user a single `u`, not one per trimmed line.
    write(ROOT, ".editorconfig", "root = true\n[*]\ntrim_trailing_whitespace = true\n")
    local file = write(ROOT, "f.txt", "a   \nb   \nc   \nd   \n")
    open_resolved(t, file)
    -- Prepend, so the edit that dirties the buffer leaves the trailing runs intact.
    t:feed("ggI!<Esc>")

    t:cmd("write")
    on_disk(t, file, function(s)
      return s:find("!", 1, true) ~= nil
    end, "the write never landed")
    btv.test.expect(t:lines()).to_equal({ "!a", "b", "c", "d" })

    -- One press restores all four lines: the trim is a single undo entry.
    t:feed("u")
    btv.test.expect(t:lines()).to_equal({ "!a   ", "b   ", "c   ", "d   " })
  end)

  btv.test.it("warns once that insert_final_newline = false cannot be honored", function(t)
    -- bemtvi's rope always keeps a trailing newline, so the file always ends with one;
    -- saying so beats silently ignoring the setting.
    write(ROOT, ".editorconfig", "root = true\n[*]\ninsert_final_newline = false\n")
    local file = write(ROOT, "f.txt", "alpha\n")
    open_resolved(t, file)
    t:feed("GA!<Esc>")

    -- The write echoes its own "N lines written" after BufWritePre, so the message
    -- line no longer holds the warning by the time the save settles — record the
    -- notify calls instead.
    local notes, real = {}, btv.notify
    btv.notify = function(msg, ...)
      notes[#notes + 1] = tostring(msg)
      return real(msg, ...)
    end
    t:cmd("write")
    local text = on_disk(t, file, function(s)
      return s:find("!", 1, true) ~= nil
    end, "the write never landed")
    t:cmd("write") -- a second save must NOT warn again
    t:sleep(50)
    btv.notify = real

    btv.test.expect(text).to_be("alpha!\n")
    local hits = 0
    for _, m in ipairs(notes) do
      if m:find("insert_final_newline", 1, true) then
        hits = hits + 1
      end
    end
    btv.test.expect(hits).to_be(1)
  end)

  btv.test.it("satisfies insert_final_newline = true with no work", function(t)
    write(ROOT, ".editorconfig", "root = true\n[*]\ninsert_final_newline = true\n")
    local file = write(ROOT, "f.txt", "alpha\n")
    open_resolved(t, file)
    t:feed("GA!<Esc>")

    t:cmd("write")
    local text = on_disk(t, file, function(s)
      return s:find("!", 1, true) ~= nil
    end, "the write never landed")
    btv.test.expect(text).to_be("alpha!\n")
  end)
end)
