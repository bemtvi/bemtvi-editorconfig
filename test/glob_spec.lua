-- The section-glob dialect: brace expansion and the matcher. Pure functions, so
-- these run without touching the editor at all.

local glob = require("nxvim-editorconfig.glob")

nx.test.describe("nxvim-editorconfig.glob brace expansion", function()
  nx.test.it("expands comma alternation", function()
    nx.test.expect(glob.expand_braces("*.{js,ts}")).to_equal({ "*.js", "*.ts" })
  end)

  nx.test.it("expands nested groups", function()
    nx.test.expect(glob.expand_braces("{a,b{c,d}}")).to_equal({ "a", "bc", "bd" })
  end)

  nx.test.it("expands a numeric range, ascending and descending", function()
    nx.test.expect(glob.expand_braces("f{1..3}")).to_equal({ "f1", "f2", "f3" })
    nx.test.expect(glob.expand_braces("f{3..1}")).to_equal({ "f3", "f2", "f1" })
  end)

  nx.test.it("leaves a single-element group as a literal", function()
    nx.test.expect(glob.expand_braces("a{x}b")).to_equal({ "a{x}b" })
  end)
end)

nx.test.describe("nxvim-editorconfig.glob matching", function()
  nx.test.it("`*` does not cross a path separator", function()
    nx.test.expect(glob.match_glob("*.lua", "init.lua")).to_be(true)
    nx.test.expect(glob.match_glob("*.lua", "src/init.lua")).to_be(false)
  end)

  nx.test.it("`**` crosses separators and `**/` also matches zero segments", function()
    nx.test.expect(glob.match_glob("**.lua", "a/b/c.lua")).to_be(true)
    nx.test.expect(glob.match_glob("**/init.lua", "init.lua")).to_be(true)
    nx.test.expect(glob.match_glob("**/init.lua", "a/b/init.lua")).to_be(true)
  end)

  nx.test.it("`?` matches exactly one non-separator char", function()
    nx.test.expect(glob.match_glob("a?c", "abc")).to_be(true)
    nx.test.expect(glob.match_glob("a?c", "ac")).to_be(false)
    nx.test.expect(glob.match_glob("a?c", "a/c")).to_be(false)
  end)

  nx.test.it("matches character classes, ranges, and negation", function()
    nx.test.expect(glob.match_glob("[abc].txt", "b.txt")).to_be(true)
    nx.test.expect(glob.match_glob("[a-c].txt", "c.txt")).to_be(true)
    nx.test.expect(glob.match_glob("[!a-c].txt", "d.txt")).to_be(true)
    nx.test.expect(glob.match_glob("[!a-c].txt", "b.txt")).to_be(false)
  end)

  nx.test.it("treats an unclosed `[` as a literal instead of erroring", function()
    nx.test.expect(glob.match_glob("a[b", "a[b")).to_be(true)
  end)
end)

nx.test.describe("nxvim-editorconfig.glob section headers", function()
  nx.test.it("a separator-less header matches the basename at any depth", function()
    nx.test.expect(glob.section_matches("*.py", "deep/nested/app.py")).to_be(true)
  end)

  nx.test.it("a leading `/` anchors to the config directory", function()
    nx.test.expect(glob.section_matches("/main.txt", "main.txt")).to_be(true)
    nx.test.expect(glob.section_matches("/main.txt", "sub/main.txt")).to_be(false)
  end)

  nx.test.it("a header containing `/` is relative to the config directory", function()
    nx.test.expect(glob.section_matches("sub/*.txt", "sub/a.txt")).to_be(true)
    nx.test.expect(glob.section_matches("sub/*.txt", "other/a.txt")).to_be(false)
  end)

  nx.test.it("expands brace groups in the header", function()
    nx.test.expect(glob.section_matches("*.{js,ts}", "a.ts")).to_be(true)
    nx.test.expect(glob.section_matches("*.{js,ts}", "a.py")).to_be(false)
  end)
end)

-- Why this module exists at all, as a test rather than a comment.
--
-- nxvim ships ONE glob engine (`nx.glob` — globset compiled to a cached Rust regex),
-- so a plugin carrying its own matcher has to justify itself. These pin the exact
-- points where EditorConfig's dialect and `nx.glob`'s shell/gitignore dialect
-- disagree: the cases where swapping in `nx.glob` would look right and silently stop
-- matching. If the core ever grows this dialect, these fail — and that failure is the
-- signal to delete `glob.lua` rather than a regression.
nx.test.describe("nxvim-editorconfig.glob vs nx.glob", function()
  nx.test.it("`**` crosses `/` anywhere, where nx.glob wants a whole component", function()
    -- EditorConfig: `**` is "any run of characters", `/` included, wherever it sits.
    nx.test.expect(glob.match_glob("**.js", "a/b/c.js")).to_be(true)
    nx.test.expect(glob.match_glob("a**z", "a/mn/z")).to_be(true)
    -- nx.glob: `**` is recursive only as its own path component, so both degrade to
    -- `[^/]*[^/]*` and stop at the first separator.
    nx.test.expect(nx.glob.match("**.js", "a/b/c.js")).to_be(false)
    nx.test.expect(nx.glob.match("a**z", "a/mn/z")).to_be(false)
    -- The spelling both dialects agree on — the divergence is narrow, not wholesale.
    nx.test.expect(glob.match_glob("**/init.lua", "a/b/init.lua")).to_be(true)
    nx.test.expect(nx.glob.match("**/init.lua", "a/b/init.lua")).to_be(true)
  end)

  nx.test.it("`{m..n}` is a numeric range, which nx.glob has no notion of", function()
    nx.test.expect(glob.section_matches("f{1..3}", "f2")).to_be(true)
    -- To nx.glob a comma-less `{…}` is a single literal alternative, so `f{1..3}`
    -- matches only the text `f1..3`.
    nx.test.expect(nx.glob.match("f{1..3}", "f2")).to_be(false)
  end)
end)
