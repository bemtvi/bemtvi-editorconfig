-- EditorConfig section-glob matching.
--
-- A `.editorconfig` section header is a glob in EditorConfig's own dialect — close
-- to a shell glob, with brace alternation (`{a,b}`), numeric ranges (`{1..9}`),
-- `**` for "any run including `/`", and `[...]` classes. Nothing in Lua matches it,
-- so this module implements it: brace expansion into plain globs, then a
-- backtracking matcher over one glob.
--
-- Exported (rather than kept private to `init.lua`) because the matcher is the part
-- with the most corner cases, and the test suite exercises it directly.

local M = {}

-- Expand EditorConfig brace groups — `{a,b,c}` alternation and `{m..n}` numeric
-- ranges — into a flat list of plain globs (no braces). Nested groups are handled
-- by re-expanding the substituted result. A single-element group with no comma or
-- range (e.g. `{x}`) is treated as a literal and left in place.
function M.expand_braces(g)
  local i = 1
  while i <= #g do
    local c = g:sub(i, i)
    if c == "\\" then
      i = i + 2
    elseif c == "{" then
      -- Scan to the matching `}`, recording top-level comma split points.
      local depth, j = 1, i + 1
      local parts, start = {}, i + 1
      while j <= #g and depth > 0 do
        local cj = g:sub(j, j)
        if cj == "\\" then
          j = j + 1
        elseif cj == "{" then
          depth = depth + 1
        elseif cj == "}" then
          depth = depth - 1
          if depth == 0 then
            break
          end
        elseif cj == "," and depth == 1 then
          parts[#parts + 1] = g:sub(start, j - 1)
          start = j + 1
        end
        j = j + 1
      end
      if depth == 0 then
        local prefix, suffix = g:sub(1, i - 1), g:sub(j + 1)
        if #parts > 0 then
          parts[#parts + 1] = g:sub(start, j - 1)
          local out = {}
          for _, p in ipairs(parts) do
            for _, sub in ipairs(M.expand_braces(prefix .. p .. suffix)) do
              out[#out + 1] = sub
            end
          end
          return out
        end
        local lo, hi = g:sub(i + 1, j - 1):match("^(-?%d+)%.%.(-?%d+)$")
        if lo then
          lo, hi = tonumber(lo), tonumber(hi)
          local step = (lo <= hi) and 1 or -1
          local out = {}
          for n = lo, hi, step do
            for _, sub in ipairs(M.expand_braces(prefix .. tostring(n) .. suffix)) do
              out[#out + 1] = sub
            end
          end
          return out
        end
        -- Literal single-element brace: skip past it and keep scanning.
        i = j + 1
      else
        i = i + 1
      end
    else
      i = i + 1
    end
  end
  return { g }
end

-- Parse a `[...]` character class starting at index `gi` (the `[`). Returns a
-- predicate over a single char and the index just past the closing `]`, or nil if
-- there is no closing `]` (so the caller treats `[` as a literal).
local function parse_class(g, gi)
  local j = gi + 1
  local neg = false
  if g:sub(j, j) == "!" then
    neg = true
    j = j + 1
  end
  local ranges = {}
  local first = true
  while j <= #g do
    local cj = g:sub(j, j)
    if cj == "]" and not first then
      break
    end
    first = false
    if cj == "\\" then
      cj = g:sub(j + 1, j + 1)
      ranges[#ranges + 1] = { cj, cj }
      j = j + 2
    elseif
      g:sub(j + 1, j + 1) == "-"
      and g:sub(j + 2, j + 2) ~= "]"
      and g:sub(j + 2, j + 2) ~= ""
    then
      ranges[#ranges + 1] = { cj, g:sub(j + 2, j + 2) }
      j = j + 3
    else
      ranges[#ranges + 1] = { cj, cj }
      j = j + 1
    end
  end
  if j > #g then
    return nil
  end
  return function(ch)
    if ch == "" then
      return false
    end
    local hit = false
    for _, r in ipairs(ranges) do
      if ch >= r[1] and ch <= r[2] then
        hit = true
        break
      end
    end
    if neg then
      return not hit
    end
    return hit
  end,
    j + 1
end

-- Match a brace-free EditorConfig glob `g` against path `p` (both `/`-separated),
-- by recursive backtracking. `*` matches any run without `/`; `**` any run
-- including `/`; `**/` additionally matches zero path segments; `?` one non-`/`
-- char; `[...]` a class. Backslash escapes the next char.
function M.match_glob(g, p)
  local function m(gi, pi)
    while gi <= #g do
      local c = g:sub(gi, gi)
      if c == "*" then
        if g:sub(gi + 1, gi + 1) == "*" then
          gi = gi + 2
          if g:sub(gi, gi) == "/" then
            -- `**/`: zero or more whole directory segments.
            local rest = gi + 1
            if m(rest, pi) then
              return true
            end
            for k = pi, #p do
              if p:sub(k, k) == "/" and m(rest, k + 1) then
                return true
              end
            end
            return false
          end
          -- bare `**`: any run including `/`.
          for k = pi, #p + 1 do
            if m(gi, k) then
              return true
            end
          end
          return false
        end
        -- `*`: any run not crossing `/`.
        gi = gi + 1
        for k = pi, #p + 1 do
          if k > pi and p:sub(k - 1, k - 1) == "/" then
            break
          end
          if m(gi, k) then
            return true
          end
        end
        return false
      elseif c == "?" then
        local pc = p:sub(pi, pi)
        if pc == "" or pc == "/" then
          return false
        end
        gi, pi = gi + 1, pi + 1
      elseif c == "[" then
        local pred, nexti = parse_class(g, gi)
        if not pred then
          if p:sub(pi, pi) ~= "[" then
            return false
          end
          gi, pi = gi + 1, pi + 1
        else
          local pc = p:sub(pi, pi)
          if pc == "/" or not pred(pc) then
            return false
          end
          gi, pi = nexti, pi + 1
        end
      elseif c == "\\" then
        if p:sub(pi, pi) ~= g:sub(gi + 1, gi + 1) then
          return false
        end
        gi, pi = gi + 2, pi + 1
      else
        if p:sub(pi, pi) ~= c then
          return false
        end
        gi, pi = gi + 1, pi + 1
      end
    end
    return pi > #p
  end
  return m(1, 1)
end

-- Does section header `glob` (from a `.editorconfig` in some directory) match the
-- file path `rel` (relative to that directory, `/`-separated)? A glob with no `/`
-- matches the basename at any depth (`**/` is implied); a leading `/` anchors to
-- the config directory; any other `/` makes it relative to the config directory.
function M.section_matches(glob, rel)
  local g = glob
  if g:sub(1, 1) == "/" then
    g = g:sub(2)
  elseif not g:find("/", 1, true) then
    g = "**/" .. g
  end
  for _, e in ipairs(M.expand_braces(g)) do
    if M.match_glob(e, rel) then
      return true
    end
  end
  return false
end

return M
