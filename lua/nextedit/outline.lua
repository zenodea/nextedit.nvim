-- A cheap file outline: definition nodes from treesitter, one numbered line
-- each, so the model can see the file's structure beyond the excerpt — and
-- knows the absolute line numbers of definitions it might want to reference.
-- Language-agnostic on purpose: node-type name matching instead of per-parser
-- queries covers every bundled and community parser well enough.
local M = {}

local MAX_ENTRIES = 40
local MAX_DEPTH = 4

local function is_definition(node_type)
  if node_type:find("call", 1, true) then
    return false -- "function_call" and friends
  end
  for _, kind in ipairs({ "function", "method", "class", "struct", "enum", "interface", "impl", "module", "trait" }) do
    if node_type:find(kind, 1, true) then
      return true
    end
  end
  return false
end

--- Outline entries for buf ("<lnum>| <definition line>"), or {} when no
--- parser is available.
function M.get(buf)
  local ok, parser = pcall(vim.treesitter.get_parser, buf)
  if not ok or not parser then
    return {}
  end
  local parsed, trees = pcall(parser.parse, parser)
  if not parsed or not trees or not trees[1] then
    return {}
  end
  local out = {}
  local function walk(node, depth)
    if depth > MAX_DEPTH or #out >= MAX_ENTRIES then
      return
    end
    for child in node:iter_children() do
      if child:named() then
        if is_definition(child:type()) then
          local lnum = child:range() -- 0-based start row
          local line = vim.api.nvim_buf_get_lines(buf, lnum, lnum + 1, false)[1] or ""
          out[#out + 1] = ("%5d| %s"):format(lnum + 1, vim.trim(line))
        end
        walk(child, depth + 1)
      end
    end
  end
  walk(trees[1]:root(), 1)
  return out
end

return M
