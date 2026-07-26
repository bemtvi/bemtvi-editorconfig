-- The `.editorconfig` file parser.

local parse = require("nxvim-editorconfig.parse").parse

nx.test.describe("nxvim-editorconfig.parse", function()
  nx.test.it("reads the preamble `root` and each section in file order", function()
    local cfg = parse("root = true\n[*]\nindent_size = 2\n[*.py]\nindent_size = 4\n")
    nx.test.expect(cfg.root).to_be(true)
    nx.test.expect(#cfg.sections).to_be(2)
    nx.test.expect(cfg.sections[1].glob).to_be("*")
    nx.test.expect(cfg.sections[2].glob).to_be("*.py")
    nx.test.expect(cfg.sections[2].props.indent_size).to_be("4")
  end)

  nx.test.it("defaults root to false and lowercases keys and values", function()
    local cfg = parse("[*]\nIndent_Style = Space\nEnd_Of_Line = CRLF\n")
    nx.test.expect(cfg.root).to_be(false)
    nx.test.expect(cfg.sections[1].props.indent_style).to_be("space")
    nx.test.expect(cfg.sections[1].props.end_of_line).to_be("crlf")
  end)

  nx.test.it("ignores blank lines and `#` / `;` comments", function()
    local cfg = parse("# hi\n; there\n\n[*]\n\n# again\nindent_size = 3\n")
    nx.test.expect(#cfg.sections).to_be(1)
    nx.test.expect(cfg.sections[1].props.indent_size).to_be("3")
  end)

  nx.test.it("trims whitespace around the `=` and accepts CRLF line endings", function()
    local cfg = parse("[*]\r\n  indent_size   =   6   \r\n")
    nx.test.expect(cfg.sections[1].props.indent_size).to_be("6")
  end)

  nx.test.it("keeps a property outside any section out of the sections", function()
    local cfg = parse("indent_size = 9\n[*]\nindent_size = 1\n")
    nx.test.expect(cfg.sections[1].props.indent_size).to_be("1")
  end)
end)
