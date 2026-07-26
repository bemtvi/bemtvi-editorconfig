-- The `.editorconfig` INI-ish parser.
--
-- One file becomes `{ root = <bool>, sections = { { glob = , props = }, … } }` —
-- the preamble's `root` (which stops the upward search) plus each `[glob]` section
-- in file order, since a later matching section overrides an earlier one.

local M = {}

-- Parse `.editorconfig` text. Keys and values are lowercased (EditorConfig property
-- names, and the values acted on, are all case-insensitive); `=` is the sole
-- property delimiter; blank lines and `#` / `;` comments are ignored.
function M.parse(text)
  local cfg = { root = false, sections = {} }
  local section -- props table of the current `[glob]` (nil = preamble)
  for raw in (text .. "\n"):gmatch("(.-)\r?\n") do
    local line = raw:gsub("^%s+", ""):gsub("%s+$", "")
    local first = line:sub(1, 1)
    if first == "[" and line:sub(-1) == "]" then
      section = {}
      cfg.sections[#cfg.sections + 1] = { glob = line:sub(2, -2), props = section }
    elseif line ~= "" and first ~= "#" and first ~= ";" then
      local k, v = line:match("^([^=]+)=(.*)$")
      if k then
        k = k:gsub("%s+$", ""):lower()
        v = v:gsub("^%s+", ""):gsub("%s+$", ""):lower()
        if section then
          section[k] = v
        elseif k == "root" then
          cfg.root = (v == "true")
        end
      end
    end
  end
  return cfg
end

return M
