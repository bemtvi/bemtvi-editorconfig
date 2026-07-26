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
