-- Display and text helpers for the JSON Preview plugin.
--
-- Split out of the 1.x main.lua; the helper bodies are unchanged. Everything
-- here is self-contained (no sibling requires) so both the parser consumers
-- and the tree/meta/main modules can depend on it freely.

local M = {}

local MAX_STRING_DISPLAY = 200
local MAX_KEY_DISPLAY = 120
local MAX_NUMBER_DISPLAY = 80
-- Shared cap for a rendered panel line; tree and meta line builders clip to it.
local MAX_LINE_BYTES = 3500

-- ===========================================================================
-- Text helpers
-- ===========================================================================

local function normalize_text(text)
  text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
  if text:sub(1, 3) == "\239\187\191" then
    text = text:sub(4)
  end
  return text
end

local function utf8_prefix(text, max_bytes)
  if #text <= max_bytes then
    return text
  end
  local cut = max_bytes
  while cut > 0 do
    local byte = text:byte(cut + 1)
    if byte and byte >= 0x80 and byte < 0xC0 then
      cut = cut - 1
    else
      break
    end
  end
  if cut <= 0 then
    return ""
  end
  return text:sub(1, cut)
end

local function codepoint_width(cp)
  if cp == 0 then
    return 0
  end
  if cp < 32 or (cp >= 0x7F and cp < 0xA0) then
    return 0
  end
  if (cp >= 0x0300 and cp <= 0x036F)
    or (cp >= 0x1AB0 and cp <= 0x1AFF)
    or (cp >= 0x1DC0 and cp <= 0x1DFF)
    or (cp >= 0x20D0 and cp <= 0x20FF)
    or (cp >= 0xFE20 and cp <= 0xFE2F)
  then
    return 0
  end
  if (cp >= 0x1100 and cp <= 0x115F)
    or (cp >= 0x2E80 and cp <= 0xA4CF and cp ~= 0x303F)
    or (cp >= 0xAC00 and cp <= 0xD7A3)
    or (cp >= 0xF900 and cp <= 0xFAFF)
    or (cp >= 0xFE10 and cp <= 0xFE19)
    or (cp >= 0xFE30 and cp <= 0xFE6F)
    or (cp >= 0xFF00 and cp <= 0xFF60)
    or (cp >= 0xFFE0 and cp <= 0xFFE6)
    or (cp >= 0x1F300 and cp <= 0x1F64F)
    or (cp >= 0x1F900 and cp <= 0x1F9FF)
    or (cp >= 0x20000 and cp <= 0x3FFFD)
  then
    return 2
  end
  return 1
end

local function display_width(text)
  local ok, width = pcall(function()
    local total = 0
    for _, cp in utf8.codes(text) do
      total = total + codepoint_width(cp)
    end
    return total
  end)
  if ok then
    return width
  end
  return #text
end

-- Return at most `limit` display columns starting at display column `skip`.
local function display_slice(text, skip, limit)
  local out = {}
  local used = 0
  local skipped = 0
  local ok = pcall(function()
    for _, cp in utf8.codes(text) do
      local width = codepoint_width(cp)
      if skipped < skip then
        skipped = skipped + width
      elseif used + width <= limit then
        out[#out + 1] = utf8.char(cp)
        used = used + width
      else
        break
      end
    end
  end)
  if not ok then
    return utf8_prefix(text, limit), skip, math.min(display_width(text), limit)
  end
  return table.concat(out), skipped, used
end

local function format_bytes(count)
  if count < 1024 then
    return count .. " B"
  end
  if count < 1024 * 1024 then
    return string.format("%.1f KiB", count / 1024)
  end
  return string.format("%.1f MiB", count / (1024 * 1024))
end

local function plural(count, one, many)
  if count == 1 then
    return one
  end
  return many
end

local function char_count(value)
  local count = utf8.len(value)
  if count == nil then
    return #value
  end
  return count
end

local function sanitize_excerpt(text)
  text = text:gsub("\t", "    ")
  text = text:gsub("[%z\1-\8\11\12\14-\31\127]", "?")
  return text
end

local function trim(text)
  return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function clip_text(text, limit)
  if #text <= limit then
    return text
  end
  return utf8_prefix(text, limit) .. "…"
end

-- ===========================================================================
-- Encoding and display helpers
-- ===========================================================================

local function escape_codepoint(cp)
  if cp == 34 then
    return '\\"', 2
  elseif cp == 92 then
    return "\\\\", 2
  elseif cp == 8 then
    return "\\b", 2
  elseif cp == 12 then
    return "\\f", 2
  elseif cp == 10 then
    return "\\n", 2
  elseif cp == 13 then
    return "\\r", 2
  elseif cp == 9 then
    return "\\t", 2
  elseif cp < 32 or (cp >= 127 and cp <= 159) then
    return string.format("\\u%04X", cp), 6
  end
  return utf8.char(cp), codepoint_width(cp)
end

local function encode_string(value)
  local out = { '"' }
  for _, cp in utf8.codes(value) do
    out[#out + 1] = escape_codepoint(cp)
  end
  out[#out + 1] = '"'
  return table.concat(out)
end

-- Quote a string for the panel. Returns the display text, whether it was cut
-- and the total character count.
local function display_string(value, budget)
  local total = char_count(value)
  local out = { '"' }
  local used = 0
  local truncated = false
  local ok = pcall(function()
    for _, cp in utf8.codes(value) do
      local piece, width = escape_codepoint(cp)
      if used + width > budget then
        truncated = true
        break
      end
      out[#out + 1] = piece
      used = used + width
    end
  end)
  if not ok then
    return encode_string(utf8_prefix(value, budget)), false, total
  end
  if truncated then
    out[#out + 1] = "…"
  end
  out[#out + 1] = '"'
  return table.concat(out), truncated, total
end

local function display_number(raw)
  if #raw <= MAX_NUMBER_DISPLAY then
    return raw, false
  end
  return utf8_prefix(raw, MAX_NUMBER_DISPLAY - 1) .. "…", true
end

local function describe_node(node)
  if node.type == "object" then
    return string.format("Object · %d %s", #node.pairs, plural(#node.pairs, "key", "keys"))
  elseif node.type == "array" then
    return string.format("Array · %d %s", #node.items, plural(#node.items, "item", "items"))
  elseif node.type == "string" then
    local count = char_count(node.value)
    return string.format("String · %d %s", count, plural(count, "char", "chars"))
  elseif node.type == "number" then
    local raw = display_number(node.raw)
    return "Number · " .. raw
  elseif node.type == "boolean" then
    return "Boolean · " .. tostring(node.value)
  end
  return "Null"
end

local function count_duplicates(node)
  if node.type == "object" then
    local total = node.duplicates or 0
    for _, pair in ipairs(node.pairs) do
      total = total + count_duplicates(pair.value)
    end
    return total
  elseif node.type == "array" then
    local total = 0
    for _, item in ipairs(node.items) do
      total = total + count_duplicates(item)
    end
    return total
  end
  return 0
end

local function ordered_pairs(node, sort_keys)
  if not sort_keys then
    return node.pairs
  end
  local pairs = {}
  for index, pair in ipairs(node.pairs) do
    pairs[index] = pair
  end
  table.sort(pairs, function(left, right)
    if left.key == right.key then
      return left.index < right.index
    end
    return left.key < right.key
  end)
  return pairs
end

M.MAX_STRING_DISPLAY = MAX_STRING_DISPLAY
M.MAX_KEY_DISPLAY = MAX_KEY_DISPLAY
M.MAX_LINE_BYTES = MAX_LINE_BYTES
M.normalize_text = normalize_text
M.utf8_prefix = utf8_prefix
M.codepoint_width = codepoint_width
M.display_width = display_width
M.display_slice = display_slice
M.format_bytes = format_bytes
M.plural = plural
M.char_count = char_count
M.sanitize_excerpt = sanitize_excerpt
M.trim = trim
M.clip_text = clip_text
M.escape_codepoint = escape_codepoint
M.encode_string = encode_string
M.display_string = display_string
M.display_number = display_number
M.describe_node = describe_node
M.count_duplicates = count_duplicates
M.ordered_pairs = ordered_pairs

return M
