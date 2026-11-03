-- JSON Preview for Luban Notepad.
--
-- A self-contained strict JSON parser and panel renderer for the sandboxed Lua
-- plugin runtime. It reads the active document through luban.get_document() and
-- never touches the file system or the network.
--
-- Rich spans, panel width and edit-driven refresh require Luban Notepad
-- 1.0.0-preview.2 or newer. Older hosts ignore style/spans/width/refresh and
-- render the plain `text` fallback, which every line always provides.

local M = {}

local MAX_SOURCE_BYTES = 512 * 1024
local MAX_COMMAND_BYTES = 512 * 1024
local MAX_RENDER_LINES = 4000
local MAX_LINE_BYTES = 3500
local MAX_DEPTH = 256
local MAX_STRING_DISPLAY = 200
local MAX_KEY_DISPLAY = 120
local MAX_NUMBER_DISPLAY = 80
local MAX_ERROR_COLUMNS = 160

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

-- ===========================================================================
-- JSON parser
-- ===========================================================================

local function fail(parser, message, pos)
  error({ json_error = true, message = message, pos = pos or parser.pos }, 0)
end

local function skip_ws(parser)
  local text = parser.text
  local pos = parser.pos
  local n = parser.n
  while pos <= n do
    local byte = text:byte(pos)
    if byte == 32 or byte == 9 or byte == 10 or byte == 13 then
      pos = pos + 1
    else
      break
    end
  end
  parser.pos = pos
end

local function is_digit(byte)
  return byte ~= nil and byte >= 48 and byte <= 57
end

local function is_hex(byte)
  return byte ~= nil
    and ((byte >= 48 and byte <= 57) or (byte >= 65 and byte <= 70) or (byte >= 97 and byte <= 102))
end

local function parse_string(parser)
  local text = parser.text
  local n = parser.n
  local start = parser.pos
  parser.pos = parser.pos + 1
  local content_start = parser.pos
  local out = {}
  while true do
    if parser.pos > n then
      fail(parser, "Unterminated string", start)
    end
    local byte = text:byte(parser.pos)
    if byte == 34 then
      local chunk = text:sub(content_start, parser.pos - 1)
      if chunk ~= "" then
        out[#out + 1] = chunk
      end
      parser.pos = parser.pos + 1
      return table.concat(out)
    elseif byte == 92 then
      local chunk = text:sub(content_start, parser.pos - 1)
      if chunk ~= "" then
        out[#out + 1] = chunk
      end
      parser.pos = parser.pos + 1
      if parser.pos > n then
        fail(parser, "Unterminated escape sequence", parser.pos - 1)
      end
      local escape = text:sub(parser.pos, parser.pos)
      if escape == '"' then
        out[#out + 1] = '"'
        parser.pos = parser.pos + 1
      elseif escape == "\\" then
        out[#out + 1] = "\\"
        parser.pos = parser.pos + 1
      elseif escape == "/" then
        out[#out + 1] = "/"
        parser.pos = parser.pos + 1
      elseif escape == "b" then
        out[#out + 1] = "\b"
        parser.pos = parser.pos + 1
      elseif escape == "f" then
        out[#out + 1] = "\f"
        parser.pos = parser.pos + 1
      elseif escape == "n" then
        out[#out + 1] = "\n"
        parser.pos = parser.pos + 1
      elseif escape == "r" then
        out[#out + 1] = "\r"
        parser.pos = parser.pos + 1
      elseif escape == "t" then
        out[#out + 1] = "\t"
        parser.pos = parser.pos + 1
      elseif escape == "u" then
        local hex_start = parser.pos + 1
        local hex = text:sub(hex_start, hex_start + 3)
        if #hex < 4 then
          parser.pos = n
          fail(parser, "Invalid \\u escape", hex_start)
        end
        for i = 1, 4 do
          if not is_hex(text:byte(hex_start + i - 1)) then
            fail(parser, "Invalid \\u escape", hex_start)
          end
        end
        local cp = tonumber(hex, 16)
        parser.pos = hex_start + 4
        if cp >= 0xD800 and cp <= 0xDBFF then
          if text:sub(parser.pos, parser.pos + 1) ~= "\\u" then
            fail(parser, "Unpaired high surrogate in a string", parser.pos)
          end
          local low_start = parser.pos + 2
          local low_hex = text:sub(low_start, low_start + 3)
          if #low_hex < 4 then
            parser.pos = n
            fail(parser, "Invalid \\u escape", low_start)
          end
          for i = 1, 4 do
            if not is_hex(text:byte(low_start + i - 1)) then
              fail(parser, "Invalid \\u escape", low_start)
            end
          end
          local low = tonumber(low_hex, 16)
          if low < 0xDC00 or low > 0xDFFF then
            fail(parser, "Unpaired high surrogate in a string", low_start - 2)
          end
          cp = 0x10000 + (cp - 0xD800) * 1024 + (low - 0xDC00)
          parser.pos = low_start + 4
        elseif cp >= 0xDC00 and cp <= 0xDFFF then
          fail(parser, "Unpaired low surrogate in a string", parser.pos - 4)
        end
        out[#out + 1] = utf8.char(cp)
      else
        fail(parser, "Invalid escape sequence '\\" .. escape .. "'", parser.pos - 1)
      end
      content_start = parser.pos
    elseif byte < 32 then
      fail(parser, string.format("Unescaped control character U+%04X in a string", byte), parser.pos)
    else
      parser.pos = parser.pos + 1
    end
  end
end

local function parse_number(parser)
  local text = parser.text
  local start = parser.pos
  local byte = text:byte(parser.pos)
  if byte == 45 then
    parser.pos = parser.pos + 1
    byte = text:byte(parser.pos)
    if byte == nil then
      fail(parser, "Invalid number", start)
    end
  end
  if byte == 48 then
    parser.pos = parser.pos + 1
    if is_digit(text:byte(parser.pos)) then
      fail(parser, "Leading zeros are not allowed in numbers", start)
    end
  elseif is_digit(byte) then
    while is_digit(text:byte(parser.pos)) do
      parser.pos = parser.pos + 1
    end
  else
    fail(parser, "Invalid number", start)
  end
  if text:byte(parser.pos) == 46 then
    parser.pos = parser.pos + 1
    if not is_digit(text:byte(parser.pos)) then
      fail(parser, "A decimal point must be followed by a digit", start)
    end
    while is_digit(text:byte(parser.pos)) do
      parser.pos = parser.pos + 1
    end
  end
  local exponent = text:byte(parser.pos)
  if exponent == 101 or exponent == 69 then
    parser.pos = parser.pos + 1
    local sign = text:byte(parser.pos)
    if sign == 43 or sign == 45 then
      parser.pos = parser.pos + 1
    end
    if not is_digit(text:byte(parser.pos)) then
      fail(parser, "An exponent must contain at least one digit", start)
    end
    while is_digit(text:byte(parser.pos)) do
      parser.pos = parser.pos + 1
    end
  end
  return { type = "number", raw = text:sub(start, parser.pos - 1), start = start, finish = parser.pos - 1 }
end

local function parse_literal(parser)
  local text = parser.text
  local pos = parser.pos
  if text:sub(pos, pos + 3) == "true" then
    parser.pos = pos + 4
    return { type = "boolean", value = true, start = pos, finish = pos + 3 }
  elseif text:sub(pos, pos + 4) == "false" then
    parser.pos = pos + 5
    return { type = "boolean", value = false, start = pos, finish = pos + 4 }
  elseif text:sub(pos, pos + 3) == "null" then
    parser.pos = pos + 4
    return { type = "null", start = pos, finish = pos + 3 }
  end
  fail(parser, "Invalid literal; expected 'true', 'false' or 'null'", pos)
end

local parse_value

local function parse_object(parser)
  local start = parser.pos
  parser.depth = parser.depth + 1
  if parser.depth > MAX_DEPTH then
    parser.depth = parser.depth - 1
    fail(parser, string.format("Maximum nesting depth of %d exceeded", MAX_DEPTH), start)
  end
  parser.pos = parser.pos + 1
  skip_ws(parser)
  local text = parser.text
  local pairs = {}
  local seen = {}
  local duplicates = 0
  if text:byte(parser.pos) == 125 then
    parser.pos = parser.pos + 1
    parser.depth = parser.depth - 1
    return { type = "object", pairs = pairs, duplicates = 0, start = start, finish = parser.pos - 1 }
  end
  while true do
    skip_ws(parser)
    if parser.pos > parser.n then
      fail(parser, "Unexpected end of input (expected an object key)", parser.pos)
    end
    local byte = text:byte(parser.pos)
    if byte ~= 34 then
      if byte == 125 then
        fail(parser, "Trailing comma is not allowed", parser.pos)
      elseif byte == 47 then
        fail(parser, "Comments are not allowed in JSON", parser.pos)
      elseif byte == 39 then
        fail(parser, "Single-quoted strings are not valid JSON", parser.pos)
      end
      fail(parser, "Expected a quoted object key", parser.pos)
    end
    local key_pos = parser.pos
    local key = parse_string(parser)
    skip_ws(parser)
    if parser.pos > parser.n then
      fail(parser, "Unexpected end of input (expected ':')", parser.pos)
    end
    if text:byte(parser.pos) ~= 58 then
      fail(parser, "Expected ':' after an object key", parser.pos)
    end
    parser.pos = parser.pos + 1
    local value = parse_value(parser)
    local pair = {
      key = key,
      key_pos = key_pos,
      value = value,
      index = #pairs + 1,
    }
    local first = seen[key]
    if first then
      pair.duplicate_of = first
      duplicates = duplicates + 1
    else
      seen[key] = pair
    end
    pairs[#pairs + 1] = pair
    skip_ws(parser)
    if parser.pos > parser.n then
      fail(parser, "Unexpected end of input (expected ',' or '}')", parser.pos)
    end
    byte = text:byte(parser.pos)
    if byte == 44 then
      parser.pos = parser.pos + 1
      skip_ws(parser)
      if text:byte(parser.pos) == 125 then
        fail(parser, "Trailing comma is not allowed", parser.pos)
      end
    elseif byte == 125 then
      parser.pos = parser.pos + 1
      parser.depth = parser.depth - 1
      return { type = "object", pairs = pairs, duplicates = duplicates, start = start, finish = parser.pos - 1 }
    else
      if byte == 47 then
        fail(parser, "Comments are not allowed in JSON", parser.pos)
      elseif byte == 39 then
        fail(parser, "Single-quoted strings are not valid JSON", parser.pos)
      end
      fail(parser, "Expected ',' or '}' in an object", parser.pos)
    end
  end
end

local function parse_array(parser)
  local start = parser.pos
  parser.depth = parser.depth + 1
  if parser.depth > MAX_DEPTH then
    parser.depth = parser.depth - 1
    fail(parser, string.format("Maximum nesting depth of %d exceeded", MAX_DEPTH), start)
  end
  parser.pos = parser.pos + 1
  skip_ws(parser)
  local text = parser.text
  local items = {}
  if text:byte(parser.pos) == 93 then
    parser.pos = parser.pos + 1
    parser.depth = parser.depth - 1
    return { type = "array", items = items, start = start, finish = parser.pos - 1 }
  end
  while true do
    items[#items + 1] = parse_value(parser)
    skip_ws(parser)
    if parser.pos > parser.n then
      fail(parser, "Unexpected end of input (expected ',' or ']')", parser.pos)
    end
    local byte = text:byte(parser.pos)
    if byte == 44 then
      parser.pos = parser.pos + 1
      skip_ws(parser)
      if text:byte(parser.pos) == 93 then
        fail(parser, "Trailing comma is not allowed", parser.pos)
      end
    elseif byte == 93 then
      parser.pos = parser.pos + 1
      parser.depth = parser.depth - 1
      return { type = "array", items = items, start = start, finish = parser.pos - 1 }
    else
      if byte == 47 then
        fail(parser, "Comments are not allowed in JSON", parser.pos)
      end
      fail(parser, "Expected ',' or ']' in an array", parser.pos)
    end
  end
end

parse_value = function(parser)
  skip_ws(parser)
  if parser.pos > parser.n then
    fail(parser, "Unexpected end of input (expected a value)", parser.pos)
  end
  local byte = parser.text:byte(parser.pos)
  if byte == 123 then
    return parse_object(parser)
  elseif byte == 91 then
    return parse_array(parser)
  elseif byte == 34 then
    local start = parser.pos
    local value = parse_string(parser)
    return { type = "string", value = value, start = start, finish = parser.pos - 1 }
  elseif byte == 116 or byte == 102 or byte == 110 then
    return parse_literal(parser)
  elseif byte == 45 or is_digit(byte) then
    return parse_number(parser)
  elseif byte == 47 then
    fail(parser, "Comments are not allowed in JSON", parser.pos)
  elseif byte == 39 then
    fail(parser, "Single-quoted strings are not valid JSON", parser.pos)
  end
  local cp_ok, cp = pcall(utf8.codepoint, parser.text, parser.pos)
  local shown = cp_ok and utf8.char(cp) or parser.text:sub(parser.pos, parser.pos)
  if #shown > 0 and shown:byte(1) >= 32 and shown:byte(1) < 127 then
    shown = string.format("%q", shown)
  else
    shown = string.format("U+%04X", cp_ok and cp or parser.text:byte(parser.pos))
  end
  fail(parser, "Unexpected character " .. shown .. " (expected a value)", parser.pos)
end

local function parse_json(text)
  local length, bad = utf8.len(text)
  if length == nil then
    error({ json_error = true, message = "Invalid UTF-8 in the document", pos = bad or 1 }, 0)
  end
  local parser = { text = text, n = #text, pos = 1, depth = 0 }
  skip_ws(parser)
  if parser.pos > parser.n then
    fail(parser, "The document is empty", parser.pos)
  end
  local root = parse_value(parser)
  skip_ws(parser)
  if parser.pos <= parser.n then
    if parser.text:byte(parser.pos) == 47 then
      fail(parser, "Comments are not allowed in JSON", parser.pos)
    end
    fail(parser, "Unexpected trailing content", parser.pos)
  end
  return root
end

-- ===========================================================================
-- Source locations
-- ===========================================================================

local function compute_line_starts(text)
  local starts = { 1 }
  local pos = text:find("\n", 1, true)
  while pos do
    starts[#starts + 1] = pos + 1
    pos = text:find("\n", pos + 1, true)
  end
  return starts
end

local function line_number_at(starts, pos)
  local low = 1
  local high = #starts
  while low < high do
    local middle = math.floor((low + high + 1) / 2)
    if starts[middle] <= pos then
      low = middle
    else
      high = middle - 1
    end
  end
  return low
end

local function locate(text, starts, pos)
  if pos < 1 then
    pos = 1
  elseif pos > #text + 1 then
    pos = #text + 1
  end
  local line = line_number_at(starts, pos)
  local line_start = starts[line]
  local line_end = (starts[line + 1] or (#text + 1)) - 1
  local prefix = text:sub(line_start, math.min(pos - 1, line_end))
  local column = utf8.len(prefix)
  if column == nil then
    column = #prefix
  end
  return {
    line = line,
    column = column + 1,
    line_start = line_start,
    line_end = line_end,
    byte = pos,
  }
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

-- ===========================================================================
-- JSONPath, document positions and fold state
-- ===========================================================================

local MAX_FOLD_ENTRIES = 10000
local MAX_PATH_BYTES = 2048

local fold_state = {
  doc_key = nil,
  signature = nil,
  level = nil,
  collapsed = {},
  count = 0,
  seeded = false,
}

local function trim(text)
  return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Very deep documents can otherwise build paths quadratic in the source size.
-- Keep paths bounded; the suffix hash still keeps sibling fold identities apart.
local function shorten_path(path)
  if #path <= MAX_PATH_BYTES then
    return path
  end
  local hash = 5381
  for index = 1, #path do
    hash = (hash * 33 + path:byte(index)) % 4294967296
  end
  return utf8_prefix(path, MAX_PATH_BYTES - 10) .. "#" .. string.format("%08x", hash)
end

local function is_identifier(key)
  return key:match("^[A-Za-z_][A-Za-z0-9_]*$") ~= nil
end

local function append_key_path(path, key)
  if is_identifier(key) then
    return shorten_path(path .. "." .. key)
  end
  return shorten_path(path .. "[" .. encode_string(key) .. "]")
end

local function append_index_path(path, index)
  return shorten_path(path .. "[" .. index .. "]")
end

-- Paths used for display (JSONPath) and for fold identity. Duplicate object
-- keys share a display path, so their fold path also carries the pair index.
local function child_paths(path, fold_path, pair)
  local display = append_key_path(path, pair.key)
  local fold = append_key_path(fold_path, pair.key)
  if pair.duplicate_of then
    fold = fold .. "#" .. pair.index
  end
  return display, fold
end

local function array_child_paths(path, fold_path, index)
  return append_index_path(path, index), append_index_path(fold_path, index)
end

local function walk_containers(node, depth, path, fold_path, visit)
  if node.type == "object" then
    visit(node, depth, path, fold_path)
    for _, pair in ipairs(node.pairs) do
      local child_path, child_fold = child_paths(path, fold_path, pair)
      walk_containers(pair.value, depth + 1, child_path, child_fold, visit)
    end
  elseif node.type == "array" then
    visit(node, depth, path, fold_path)
    for index, item in ipairs(node.items) do
      local child_path, child_fold = array_child_paths(path, fold_path, index - 1)
      walk_containers(item, depth + 1, child_path, child_fold, visit)
    end
  end
end

local function clear_collapsed()
  for path in pairs(fold_state.collapsed) do
    fold_state.collapsed[path] = nil
  end
  fold_state.count = 0
end

local function add_collapsed(path)
  if fold_state.count >= MAX_FOLD_ENTRIES then
    return false
  end
  if not fold_state.collapsed[path] then
    fold_state.collapsed[path] = true
    fold_state.count = fold_state.count + 1
  end
  return true
end

local function remove_collapsed(path)
  if fold_state.collapsed[path] then
    fold_state.collapsed[path] = nil
    fold_state.count = fold_state.count - 1
  end
end

local function document_key(doc)
  if type(doc.path) == "string" and doc.path ~= "" then
    return doc.path
  end
  return "<untitled>"
end

-- A cheap structural fingerprint. Editing values keeps the fold state; adding
-- or removing root keys/items resets it so stale paths do not linger.
local function roots_signature(roots)
  local parts = {}
  for _, root in ipairs(roots) do
    local node = root.node
    if node.type == "object" then
      parts[#parts + 1] = "o" .. #node.pairs
      for index = 1, math.min(#node.pairs, 24) do
        parts[#parts + 1] = utf8_prefix(node.pairs[index].key, 40)
      end
    elseif node.type == "array" then
      parts[#parts + 1] = "a" .. #node.items
    else
      parts[#parts + 1] = node.type
    end
  end
  local signature = table.concat(parts, "\0")
  if #signature > 512 then
    signature = utf8_prefix(signature, 512)
  end
  return signature
end

local function foldable(node)
  if node.type == "object" then
    return #node.pairs > 0
  elseif node.type == "array" then
    return #node.items > 0
  end
  return false
end

local function seed_fold_level(roots, level)
  if level <= 0 then
    return
  end
  for _, root in ipairs(roots) do
    local fold_root = root.fold_prefix or "$"
    walk_containers(root.node, 1, "$", fold_root, function(node, depth, _, fold_path)
      if depth > level and foldable(node) then
        add_collapsed(fold_path)
      end
    end)
  end
end

local function ensure_fold_state(doc, roots, fold_level)
  local key = document_key(doc)
  local signature = roots_signature(roots)
  if fold_state.doc_key ~= key
    or fold_state.signature ~= signature
    or fold_state.level ~= fold_level
  then
    fold_state.doc_key = key
    fold_state.signature = signature
    fold_state.level = fold_level
    clear_collapsed()
    fold_state.seeded = false
  end
  if not fold_state.seeded then
    seed_fold_level(roots, fold_level)
    fold_state.seeded = true
  end
  return fold_state
end

local function count_visible_folded(node, fold_path, collapsed)
  if node.type == "object" then
    if #node.pairs > 0 and collapsed[fold_path] then
      return 1
    end
    local total = 0
    for _, pair in ipairs(node.pairs) do
      local _, child_fold = child_paths("", fold_path, pair)
      total = total + count_visible_folded(pair.value, child_fold, collapsed)
    end
    return total
  elseif node.type == "array" then
    if #node.items > 0 and collapsed[fold_path] then
      return 1
    end
    local total = 0
    for index, item in ipairs(node.items) do
      local _, child_fold = array_child_paths("", fold_path, index - 1)
      total = total + count_visible_folded(item, child_fold, collapsed)
    end
    return total
  end
  return 0
end

local function fold_all(roots)
  clear_collapsed()
  for _, root in ipairs(roots) do
    local fold_root = root.fold_prefix or "$"
    walk_containers(root.node, 1, "$", fold_root, function(node, depth, _, fold_path)
      if depth > 1 and foldable(node) then
        add_collapsed(fold_path)
      end
    end)
  end
  fold_state.seeded = true
end

local function expand_all()
  clear_collapsed()
  fold_state.seeded = true
end

-- Find the deepest node containing a byte position. `containers` holds every
-- object/array on the path so callers can fold the enclosing node even when the
-- cursor sits on a scalar.
local function locate_node(root, pos, display_path, fold_path)
  local found = nil
  local containers = {}
  local function visit(node, path, fold)
    if type(node.start) ~= "number" or type(node.finish) ~= "number" then
      return false
    end
    if pos < node.start or pos > node.finish then
      return false
    end
    if node.type == "object" or node.type == "array" then
      containers[#containers + 1] = {
        node = node,
        path = path,
        fold_path = fold,
        depth = #containers + 1,
      }
    end
    found = { node = node, path = path, fold_path = fold, containers = containers }
    if node.type == "object" then
      for _, pair in ipairs(node.pairs) do
        local child_path, child_fold = child_paths(path, fold, pair)
        if visit(pair.value, child_path, child_fold) then
          return true
        end
      end
    elseif node.type == "array" then
      for index, item in ipairs(node.items) do
        local child_path, child_fold = array_child_paths(path, fold, index - 1)
        if visit(item, child_path, child_fold) then
          return true
        end
      end
    end
    return true
  end
  if not visit(root, display_path or "$", fold_path or "$") then
    return nil
  end
  return found
end

local function char_offset_at(text, line, column)
  local starts = compute_line_starts(text)
  line = math.max(1, math.min(line or 1, #starts))
  local line_start = starts[line]
  local line_end = (starts[line + 1] or (#text + 1)) - 1
  local line_text = text:sub(line_start, line_end)
  local chars = utf8.len(line_text)
  if chars == nil then
    chars = #line_text
  end
  column = math.max(1, math.min(column or 1, chars + 1))
  local before = text:sub(1, line_start - 1)
  local before_chars = utf8.len(before)
  if before_chars == nil then
    before_chars = #before
  end
  return before_chars + column - 1
end

local function byte_offset_at(text, char_index)
  char_index = math.max(0, char_index or 0)
  local byte = utf8.offset(text, char_index + 1)
  if not byte then
    return #text + 1
  end
  return byte
end

local function sub_chars(text, start_char, end_char)
  local count = utf8.len(text)
  if count == nil then
    count = #text
  end
  start_char = math.max(0, math.min(start_char or 0, count))
  end_char = math.max(start_char, math.min(end_char or start_char, count))
  local from = utf8.offset(text, start_char + 1) or (#text + 1)
  local to = utf8.offset(text, end_char + 1) or (#text + 1)
  if to <= from then
    return ""
  end
  return text:sub(from, to - 1)
end

-- ===========================================================================
-- Plain serialization (format and minify commands)
-- ===========================================================================

local function serialize(node, opts, depth, buffer)
  if node.type == "object" then
    local pairs = ordered_pairs(node, opts.sort_keys)
    if #pairs == 0 then
      buffer[#buffer + 1] = "{}"
      return
    end
    buffer[#buffer + 1] = "{"
    for index, pair in ipairs(pairs) do
      if index > 1 then
        buffer[#buffer + 1] = ","
      end
      if opts.pretty then
        buffer[#buffer + 1] = "\n"
        buffer[#buffer + 1] = string.rep(" ", opts.indent * (depth + 1))
      end
      buffer[#buffer + 1] = encode_string(pair.key)
      buffer[#buffer + 1] = opts.pretty and ": " or ":"
      serialize(pair.value, opts, depth + 1, buffer)
    end
    if opts.pretty then
      buffer[#buffer + 1] = "\n"
      buffer[#buffer + 1] = string.rep(" ", opts.indent * depth)
    end
    buffer[#buffer + 1] = "}"
  elseif node.type == "array" then
    if #node.items == 0 then
      buffer[#buffer + 1] = "[]"
      return
    end
    buffer[#buffer + 1] = "["
    for index, item in ipairs(node.items) do
      if index > 1 then
        buffer[#buffer + 1] = ","
      end
      if opts.pretty then
        buffer[#buffer + 1] = "\n"
        buffer[#buffer + 1] = string.rep(" ", opts.indent * (depth + 1))
      end
      serialize(item, opts, depth + 1, buffer)
    end
    if opts.pretty then
      buffer[#buffer + 1] = "\n"
      buffer[#buffer + 1] = string.rep(" ", opts.indent * depth)
    end
    buffer[#buffer + 1] = "]"
  elseif node.type == "string" then
    buffer[#buffer + 1] = encode_string(node.value)
  elseif node.type == "number" then
    buffer[#buffer + 1] = node.raw
  elseif node.type == "boolean" then
    buffer[#buffer + 1] = node.value and "true" or "false"
  else
    buffer[#buffer + 1] = "null"
  end
end

local function serialize_document(root, opts)
  local buffer = {}
  serialize(root, opts, 0, buffer)
  local text = table.concat(buffer)
  if opts.pretty then
    return text .. "\n"
  end
  return text
end

-- ===========================================================================
-- Panel rendering
-- ===========================================================================

local indent_caches = {}

local function indent_cache(indent)
  local cache = indent_caches[indent]
  if cache then
    return cache
  end
  cache = { [0] = "" }
  for depth = 1, MAX_DEPTH do
    cache[depth] = cache[depth - 1] .. string.rep(" ", indent)
  end
  indent_caches[indent] = cache
  return cache
end

local function finish_line(tokens, notes)
  local parts = {}
  local spans = {}
  for _, token in ipairs(tokens) do
    if token.text ~= "" then
      parts[#parts + 1] = token.text
      spans[#spans + 1] = {
        text = token.text,
        role = token.role,
      }
    end
  end
  if notes then
    for _, note in ipairs(notes) do
      local text = "  " .. note
      parts[#parts + 1] = text
      spans[#spans + 1] = { text = text, style = "muted" }
    end
  end
  local text = table.concat(parts)
  if text == "" then
    text = " "
  end
  if #text > MAX_LINE_BYTES then
    return { text = utf8_prefix(text, MAX_LINE_BYTES - 1) .. "…", style = "code" }
  end
  if #spans > 400 then
    spans = nil
  end
  return { text = text, style = "code", spans = spans }
end

local function push_line(renderer, line)
  if renderer.count >= MAX_RENDER_LINES then
    renderer.overflow = true
    return false
  end
  renderer.lines[#renderer.lines + 1] = line
  renderer.count = renderer.count + 1
  return true
end

local function duplicate_note(pair, line_for_pos)
  local first_line = nil
  if line_for_pos and pair.duplicate_of then
    first_line = line_for_pos(pair.duplicate_of.key_pos)
  end
  if first_line then
    local current = line_for_pos(pair.key_pos)
    if current ~= first_line then
      return string.format("duplicate key (first at line %d)", first_line)
    end
  end
  return "duplicate key"
end

local render_value

local function combine_notes(notes, opts, display_path)
  local out = {}
  if notes then
    for _, note in ipairs(notes) do
      out[#out + 1] = note
    end
  end
  if opts.show_paths and display_path then
    out[#out + 1] = display_path
  end
  if #out == 0 then
    return nil
  end
  return out
end

render_value = function(renderer, node, depth, prefix, suffix, notes, opts, line_for_pos, display_path, fold_path)
  display_path = display_path or "$"
  fold_path = fold_path or "$"
  local indents = opts.indents
  local tokens = { { text = indents[depth] } }
  for _, token in ipairs(prefix) do
    tokens[#tokens + 1] = token
  end
  if node.type == "object" then
    local pairs = ordered_pairs(node, opts.sort_keys)
    if #pairs == 0 then
      tokens[#tokens + 1] = { text = "{}", role = "punctuation.bracket" }
      if suffix ~= "" then
        tokens[#tokens + 1] = { text = suffix, role = "punctuation" }
      end
      return push_line(renderer, finish_line(tokens, combine_notes(notes, opts, display_path)))
    end
    if opts.collapsed and opts.collapsed[fold_path] then
      tokens[#tokens + 1] = { text = "▸ ", style = "muted" }
      tokens[#tokens + 1] = { text = "{", role = "punctuation.bracket" }
      tokens[#tokens + 1] = {
        text = string.format(" … %d %s ", #pairs, plural(#pairs, "key", "keys")),
        style = "muted",
      }
      tokens[#tokens + 1] = { text = "}", role = "punctuation.bracket" }
      if suffix ~= "" then
        tokens[#tokens + 1] = { text = suffix, role = "punctuation" }
      end
      return push_line(renderer, finish_line(tokens, combine_notes(notes, opts, display_path)))
    end
    tokens[#tokens + 1] = { text = "▾ ", style = "muted" }
    tokens[#tokens + 1] = { text = "{", role = "punctuation.bracket" }
    if not push_line(renderer, finish_line(tokens, combine_notes(notes, opts, display_path))) then
      return false
    end
    for index, pair in ipairs(pairs) do
      local key_text = display_string(pair.key, MAX_KEY_DISPLAY)
      local pair_notes = nil
      if pair.duplicate_of then
        pair_notes = { duplicate_note(pair, line_for_pos) }
      end
      local child_prefix = {
        { text = key_text, role = "property" },
        { text = ": ", role = "punctuation" },
      }
      local child_suffix = index < #pairs and "," or ""
      local child_display, child_fold = child_paths(display_path, fold_path, pair)
      if not render_value(renderer, pair.value, depth + 1, child_prefix, child_suffix, pair_notes, opts, line_for_pos, child_display, child_fold) then
        return false
      end
    end
    local close_tokens = {
      { text = indents[depth] },
      { text = "}", role = "punctuation.bracket" },
    }
    if suffix ~= "" then
      close_tokens[#close_tokens + 1] = { text = suffix, role = "punctuation" }
    end
    return push_line(renderer, finish_line(close_tokens))
  elseif node.type == "array" then
    if #node.items == 0 then
      tokens[#tokens + 1] = { text = "[]", role = "punctuation.bracket" }
      if suffix ~= "" then
        tokens[#tokens + 1] = { text = suffix, role = "punctuation" }
      end
      return push_line(renderer, finish_line(tokens, combine_notes(notes, opts, display_path)))
    end
    if opts.collapsed and opts.collapsed[fold_path] then
      tokens[#tokens + 1] = { text = "▸ ", style = "muted" }
      tokens[#tokens + 1] = { text = "[", role = "punctuation.bracket" }
      tokens[#tokens + 1] = {
        text = string.format(" … %d %s ", #node.items, plural(#node.items, "item", "items")),
        style = "muted",
      }
      tokens[#tokens + 1] = { text = "]", role = "punctuation.bracket" }
      if suffix ~= "" then
        tokens[#tokens + 1] = { text = suffix, role = "punctuation" }
      end
      return push_line(renderer, finish_line(tokens, combine_notes(notes, opts, display_path)))
    end
    tokens[#tokens + 1] = { text = "▾ ", style = "muted" }
    tokens[#tokens + 1] = { text = "[", role = "punctuation.bracket" }
    if not push_line(renderer, finish_line(tokens, combine_notes(notes, opts, display_path))) then
      return false
    end
    for index, item in ipairs(node.items) do
      local child_suffix = index < #node.items and "," or ""
      local child_display, child_fold = array_child_paths(display_path, fold_path, index - 1)
      if not render_value(renderer, item, depth + 1, {}, child_suffix, nil, opts, line_for_pos, child_display, child_fold) then
        return false
      end
    end
    local close_tokens = {
      { text = indents[depth] },
      { text = "]", role = "punctuation.bracket" },
    }
    if suffix ~= "" then
      close_tokens[#close_tokens + 1] = { text = suffix, role = "punctuation" }
    end
    return push_line(renderer, finish_line(close_tokens))
  end
  local value_notes = {}
  if notes then
    for _, note in ipairs(notes) do
      value_notes[#value_notes + 1] = note
    end
  end
  if node.type == "string" then
    local text, truncated, total = display_string(node.value, MAX_STRING_DISPLAY)
    tokens[#tokens + 1] = { text = text, role = "string" }
    if truncated then
      value_notes[#value_notes + 1] = string.format("%d chars total", total)
    end
  elseif node.type == "number" then
    local raw, truncated = display_number(node.raw)
    tokens[#tokens + 1] = { text = raw, role = "number" }
    if truncated then
      value_notes[#value_notes + 1] = "number truncated"
    end
  elseif node.type == "boolean" then
    tokens[#tokens + 1] = { text = node.value and "true" or "false", role = "boolean" }
  else
    tokens[#tokens + 1] = { text = "null", role = "constant" }
  end
  if suffix ~= "" then
    tokens[#tokens + 1] = { text = suffix, role = "punctuation" }
  end
  return push_line(renderer, finish_line(tokens, combine_notes(value_notes, opts, display_path)))
end

local function parse_json_lines(text)
  local records = {}
  local line = 0
  for content in (text .. "\n"):gmatch("(.-)\n") do
    line = line + 1
    if not content:match("^%s*$") then
      local ok, root = pcall(parse_json, content)
      if not ok or type(root) ~= "table" then
        return nil
      end
      records[#records + 1] = { root = root, source_line = line }
    end
  end
  if #records < 2 then
    return nil
  end
  return records
end

local function render_valid(text, root, opts, roots)
  local renderer = { lines = {}, count = 0, overflow = false }
  local duplicates = count_duplicates(root)
  local summary = describe_node(root) .. " · " .. format_bytes(#text)
  if duplicates > 0 then
    summary = summary .. " · " .. duplicates .. " " .. plural(duplicates, "duplicate key", "duplicate keys")
  end
  local folded = 0
  for _, root in ipairs(roots or {}) do
    folded = folded + count_visible_folded(root.node, root.fold_prefix or "$", opts.collapsed or {})
  end
  if folded > 0 then
    summary = summary .. " · " .. folded .. " folded"
  end
  push_line(renderer, { text = summary, style = "muted" })
  local starts = compute_line_starts(text)
  local function line_for_pos(pos)
    return line_number_at(starts, pos)
  end
  local fold_root = (roots and roots[1] and roots[1].fold_prefix) or "$"
  render_value(renderer, root, 0, {}, "", nil, opts, line_for_pos, "$", fold_root)
  if renderer.overflow then
    renderer.lines[#renderer.lines + 1] = {
      text = string.format("Preview truncated: showing the first %d lines.", MAX_RENDER_LINES),
      style = "muted",
    }
  end
  return renderer.lines
end

local function render_json_lines(text, records, opts, roots)
  local renderer = { lines = {}, count = 0, overflow = false }
  local duplicates = 0
  for _, record in ipairs(records) do
    duplicates = duplicates + count_duplicates(record.root)
  end
  local summary = string.format(
    "JSON Lines · %d %s · %s",
    #records,
    plural(#records, "record", "records"),
    format_bytes(#text)
  )
  if duplicates > 0 then
    summary = summary .. " · " .. duplicates .. " " .. plural(duplicates, "duplicate key", "duplicate keys")
  end
  local folded = 0
  for _, root in ipairs(roots or {}) do
    folded = folded + count_visible_folded(root.node, root.fold_prefix or "$", opts.collapsed or {})
  end
  if folded > 0 then
    summary = summary .. " · " .. folded .. " folded"
  end
  push_line(renderer, { text = summary, style = "muted" })
  for _, record in ipairs(records) do
    local record_summary = string.format(
      "Line %d · %s",
      record.source_line,
      describe_node(record.root)
    )
    if not push_line(renderer, { text = record_summary, style = "muted" }) then
      break
    end
    local function line_for_pos(_)
      return record.source_line
    end
    local fold_root = "L" .. record.source_line .. "$"
    if not render_value(renderer, record.root, 0, {}, "", nil, opts, line_for_pos, "$", fold_root) then
      break
    end
  end
  if renderer.overflow then
    renderer.lines[#renderer.lines + 1] = {
      text = string.format("Preview truncated: showing the first %d lines.", MAX_RENDER_LINES),
      style = "muted",
    }
  end
  return renderer.lines
end

local function render_error(text, err, truncated)
  local starts = compute_line_starts(text)
  local loc = locate(text, starts, err.pos)
  local lines = {
    {
      text = "Invalid JSON: " .. err.message,
      style = "text",
      spans = {
        { text = "Invalid JSON", style = "bold" },
        { text = ": " .. err.message },
      },
    },
    {
      text = string.format("at line %d, column %d", loc.line, loc.column),
      style = "muted",
    },
  }
  local first = math.max(1, loc.line - 1)
  local last = loc.line
  local gutter_width = #tostring(last)
  for line = first, last do
    local line_start = starts[line]
    local line_end = (starts[line + 1] or (#text + 1)) - 1
    local content = sanitize_excerpt(text:sub(line_start, line_end))
    local caret = nil
    if line == loc.line then
      local prefix = sanitize_excerpt(text:sub(line_start, math.min(err.pos - 1, line_end)))
      caret = display_width(prefix)
      local content_width = display_width(content)
      if content_width > MAX_ERROR_COLUMNS then
        local window = math.max(0, caret - math.floor(MAX_ERROR_COLUMNS / 2))
        if window + MAX_ERROR_COLUMNS > content_width then
          window = math.max(0, content_width - MAX_ERROR_COLUMNS)
        end
        local sliced, skipped = display_slice(content, window, MAX_ERROR_COLUMNS)
        local leading = skipped > 0 and "…" or ""
        local trailing = (window + MAX_ERROR_COLUMNS < content_width) and "…" or ""
        content = leading .. sliced .. trailing
        caret = caret - skipped + (leading ~= "" and 1 or 0)
        if caret < 0 then
          caret = 0
        end
      end
    elseif display_width(content) > MAX_ERROR_COLUMNS then
      content = display_slice(content, 0, MAX_ERROR_COLUMNS - 1) .. "…"
    end
    local gutter = string.format("%" .. gutter_width .. "d | ", line)
    lines[#lines + 1] = { text = gutter .. content, style = "code" }
    if line == loc.line then
      lines[#lines + 1] = {
        text = string.rep(" ", gutter_width) .. " | " .. string.rep(" ", math.max(0, caret)) .. "^",
        style = "code",
      }
    end
  end
  if truncated then
    lines[#lines + 1] = {
      text = "The document is larger than 512 KiB; only the first 512 KiB were checked.",
      style = "muted",
    }
  end
  return lines
end

local function document_title(doc)
  local path = doc.path
  if type(path) == "string" and path ~= "" then
    local name = path:match("([^/\\]+)$") or path
    return name .. " — JSON Preview"
  end
  return "JSON Preview"
end

local function render_document(doc, opts)
  local text = normalize_text(type(doc.text) == "string" and doc.text or "")
  if text:match("^%s*$") then
    return {
      title = document_title(doc),
      lines = { { text = "This document is empty.", style = "muted" } },
    }
  end
  local truncated = false
  if #text > MAX_SOURCE_BYTES then
    text = utf8_prefix(text, MAX_SOURCE_BYTES)
    truncated = true
  end
  local ok, root = pcall(parse_json, text)
  if ok then
    local roots = { { node = root, fold_prefix = "$" } }
    ensure_fold_state(doc, roots, opts.fold_level)
    local lines = render_valid(text, root, opts, roots)
    if truncated then
      lines[#lines + 1] = {
        text = "Preview truncated: the document is larger than 512 KiB.",
        style = "muted",
      }
    end
    return { title = document_title(doc), lines = lines }
  end
  if type(root) ~= "table" or not root.json_error then
    return {
      title = document_title(doc),
      lines = { { text = "JSON preview failed: " .. tostring(root), style = "muted" } },
    }
  end
  if opts.json_lines and not truncated then
    local records = parse_json_lines(text)
    if records then
      local roots = {}
      for index, record in ipairs(records) do
        roots[index] = { node = record.root, fold_prefix = "L" .. record.source_line .. "$" }
      end
      ensure_fold_state(doc, roots, opts.fold_level)
      return { title = document_title(doc), lines = render_json_lines(text, records, opts, roots) }
    end
  end
  return { title = document_title(doc), lines = render_error(text, root, truncated) }
end

-- ===========================================================================
-- Settings and commands
-- ===========================================================================

local function raw_setting(key)
  if type(luban) == "table" and type(luban.settings) == "table" and type(luban.settings.get) == "function" then
    local ok, value = pcall(luban.settings.get, key)
    if ok then
      return value
    end
  end
  return nil
end

local function setting_bool(key, default)
  local value = raw_setting(key)
  if type(value) == "boolean" then
    return value
  end
  return default
end

local function setting_int(key, default, minimum, maximum)
  local value = raw_setting(key)
  if type(value) == "number" then
    value = math.floor(value)
    if value < minimum then
      return minimum
    elseif value > maximum then
      return maximum
    end
    return value
  end
  return default
end

local function setting_string(key, default)
  local value = raw_setting(key)
  if type(value) == "string" then
    return value
  end
  return default
end

local function preview_options()
  local indent = setting_int("indent", 2, 1, 8)
  return {
    indent = indent,
    sort_keys = setting_bool("sort_keys", false),
    json_lines = setting_bool("json_lines", true),
    fold_level = setting_int("fold_level", 0, 0, 16),
    show_paths = setting_bool("show_paths", false),
    collapsed = fold_state.collapsed,
    indents = indent_cache(indent),
  }
end

local function notify(message)
  if type(luban) == "table" and type(luban.notify) == "function" then
    luban.notify(message)
  end
end

local function active_document()
  if type(luban) ~= "table" or type(luban.get_document) ~= "function" then
    return nil
  end
  local ok, doc = pcall(luban.get_document)
  if ok and type(doc) == "table" and type(doc.text) == "string" then
    return doc
  end
  return nil
end

local function describe_error(text, err)
  if type(err) == "table" and err.json_error then
    local starts = compute_line_starts(text)
    local loc = locate(text, starts, err.pos)
    return string.format("%s (line %d, column %d)", err.message, loc.line, loc.column)
  end
  return tostring(err)
end

local function prepare_document(command)
  local doc = active_document()
  if not doc then
    notify(command .. ": no editable document is active.")
    return nil, nil
  end
  local text = normalize_text(doc.text)
  if #text > MAX_COMMAND_BYTES then
    notify(command .. ": the document is larger than 512 KiB.")
    return nil, nil
  end
  local ok, root = pcall(parse_json, text)
  if not ok or type(root) ~= "table" then
    notify(command .. ": " .. describe_error(text, root))
    return nil, nil
  end
  return text, root
end

local function update_document(command, output)
  if type(luban) ~= "table" or type(luban.set_document_text) ~= "function" then
    notify(command .. ": this host cannot update documents.")
    return false
  end
  local ok, err = luban.set_document_text(output, 0, 0)
  if ok == false or (ok == nil and err ~= nil) then
    notify(command .. ": " .. tostring(err or "cannot update the document"))
    return false
  end
  return true
end

-- ===========================================================================
-- Analysis documents (single JSON value or JSON Lines)
-- ===========================================================================

local function analysis_document(command)
  local doc = active_document()
  if not doc then
    notify(command .. ": no editable document is active.")
    return nil
  end
  local raw_text = type(doc.text) == "string" and doc.text or ""
  local text = normalize_text(raw_text)
  if text:match("^%s*$") then
    notify(command .. ": the document is empty.")
    return nil
  end
  local truncated = false
  if #text > MAX_SOURCE_BYTES then
    text = utf8_prefix(text, MAX_SOURCE_BYTES)
    truncated = true
  end
  local ok, root = pcall(parse_json, text)
  if ok then
    return {
      doc = doc,
      raw_text = raw_text,
      text = text,
      kind = "json",
      root = root,
      roots = { { node = root, fold_prefix = "$" } },
      truncated = truncated,
    }
  end
  if type(root) ~= "table" or not root.json_error then
    notify(command .. ": " .. tostring(root))
    return nil
  end
  if setting_bool("json_lines", true) and not truncated then
    local records = parse_json_lines(text)
    if records then
      local roots = {}
      for index, record in ipairs(records) do
        roots[index] = { node = record.root, fold_prefix = "L" .. record.source_line .. "$" }
      end
      return {
        doc = doc,
        raw_text = raw_text,
        text = text,
        kind = "jsonl",
        records = records,
        roots = roots,
        truncated = false,
      }
    end
  end
  notify(command .. ": " .. describe_error(text, root))
  return nil
end

local function source_label(doc)
  local path = doc.path
  if type(path) == "string" and path ~= "" then
    return path:match("([^/\\]+)$") or path
  end
  return "Untitled"
end

local function doc_line(doc)
  local line = tonumber(doc.line)
  if not line or line < 1 then
    return 1
  end
  return math.floor(line)
end

local function doc_column(doc)
  local column = tonumber(doc.column)
  if not column or column < 1 then
    return 1
  end
  return math.floor(column)
end

local function clip_text(text, limit)
  if #text <= limit then
    return text
  end
  return utf8_prefix(text, limit) .. "…"
end

-- ===========================================================================
-- Metadata
-- ===========================================================================

local function new_stats()
  return {
    values = 0,
    objects = 0,
    arrays = 0,
    strings = 0,
    numbers = 0,
    booleans = 0,
    nulls = 0,
    keys = 0,
    duplicates = 0,
    duplicate_paths = {},
    empty_objects = 0,
    empty_arrays = 0,
    max_depth = 0,
    deepest_path = "$",
    deepest_label = nil,
    string_chars = 0,
    longest_string = 0,
    longest_string_path = "$",
    longest_string_label = nil,
    integer_numbers = 0,
    decimal_numbers = 0,
    exponent_numbers = 0,
    min_number = nil,
    min_number_raw = nil,
    max_number = nil,
    max_number_raw = nil,
    true_count = 0,
    false_count = 0,
    largest_object = 0,
    largest_object_path = "$",
    largest_object_label = nil,
    largest_array = 0,
    largest_array_path = "$",
    largest_array_label = nil,
    records = 0,
    top_keys = {},
  }
end

local function collect_stats(node, path, depth, stats, line_for_pos, line_label)
  stats.values = stats.values + 1
  if depth > stats.max_depth then
    stats.max_depth = depth
    stats.deepest_path = path
    stats.deepest_label = line_label
  end
  if node.type == "object" then
    stats.objects = stats.objects + 1
    local count = #node.pairs
    stats.keys = stats.keys + count
    if count == 0 then
      stats.empty_objects = stats.empty_objects + 1
    elseif count > stats.largest_object then
      stats.largest_object = count
      stats.largest_object_path = path
      stats.largest_object_label = line_label
    end
    if path == "$" and #stats.top_keys == 0 then
      for index = 1, math.min(count, 24) do
        stats.top_keys[index] = node.pairs[index].key
      end
    end
    for _, pair in ipairs(node.pairs) do
      local child_path = append_key_path(path, pair.key)
      if pair.duplicate_of then
        stats.duplicates = stats.duplicates + 1
        if #stats.duplicate_paths < 20 then
          stats.duplicate_paths[#stats.duplicate_paths + 1] = {
            path = child_path,
            line = line_for_pos and line_for_pos(pair.key_pos) or nil,
            label = line_label,
          }
        end
      end
      collect_stats(pair.value, child_path, depth + 1, stats, line_for_pos, line_label)
    end
  elseif node.type == "array" then
    stats.arrays = stats.arrays + 1
    local count = #node.items
    if count == 0 then
      stats.empty_arrays = stats.empty_arrays + 1
    elseif count > stats.largest_array then
      stats.largest_array = count
      stats.largest_array_path = path
      stats.largest_array_label = line_label
    end
    for index, item in ipairs(node.items) do
      collect_stats(item, append_index_path(path, index - 1), depth + 1, stats, line_for_pos, line_label)
    end
  elseif node.type == "string" then
    stats.strings = stats.strings + 1
    local chars = char_count(node.value)
    stats.string_chars = stats.string_chars + chars
    if chars > stats.longest_string then
      stats.longest_string = chars
      stats.longest_string_path = path
      stats.longest_string_label = line_label
    end
  elseif node.type == "number" then
    stats.numbers = stats.numbers + 1
    if node.raw:find("[eE]") then
      stats.exponent_numbers = stats.exponent_numbers + 1
    elseif node.raw:find("%.") then
      stats.decimal_numbers = stats.decimal_numbers + 1
    else
      stats.integer_numbers = stats.integer_numbers + 1
    end
    local value = tonumber(node.raw)
    if value then
      if not stats.min_number or value < stats.min_number then
        stats.min_number = value
        stats.min_number_raw = node.raw
      end
      if not stats.max_number or value > stats.max_number then
        stats.max_number = value
        stats.max_number_raw = node.raw
      end
    end
  elseif node.type == "boolean" then
    stats.booleans = stats.booleans + 1
    if node.value then
      stats.true_count = stats.true_count + 1
    else
      stats.false_count = stats.false_count + 1
    end
  else
    stats.nulls = stats.nulls + 1
  end
end

local function metadata_line(lines, text, style)
  lines[#lines + 1] = { text = clip_text(text, MAX_LINE_BYTES - 1), style = style or "text" }
end

local function stat_line(lines, label, value)
  metadata_line(lines, string.format("  %-14s %s", label, value), "code")
end

local function label_path(path, label, limit)
  local text = clip_text(path, limit)
  if label then
    return label .. " · " .. text
  end
  return text
end

local function render_metadata(analysis)
  local stats = new_stats()
  local starts = compute_line_starts(analysis.text)
  if analysis.kind == "json" then
    collect_stats(analysis.root, "$", 1, stats, function(pos)
      return line_number_at(starts, pos)
    end, nil)
  else
    stats.records = #analysis.records
    for _, record in ipairs(analysis.records) do
      collect_stats(record.root, "$", 1, stats, function(_)
        return record.source_line
      end, "Line " .. record.source_line)
    end
  end
  local chars = utf8.len(analysis.text)
  if chars == nil then
    chars = #analysis.text
  end
  local lines = {}
  local summary = string.format(
    "%s · %s · %d lines · %d chars",
    source_label(analysis.doc),
    format_bytes(#analysis.text),
    #starts,
    chars
  )
  if analysis.kind == "jsonl" then
    summary = summary .. string.format(" · %d records", stats.records)
  end
  metadata_line(lines, summary, "muted")

  metadata_line(lines, "Values", "h3")
  stat_line(lines, "Total", stats.values)
  stat_line(lines, "Objects", stats.objects)
  stat_line(lines, "Arrays", stats.arrays)
  stat_line(lines, "Strings", stats.strings)
  stat_line(lines, "Numbers", stats.numbers)
  stat_line(lines, "Booleans", stats.booleans .. string.format(" (true %d, false %d)", stats.true_count, stats.false_count))
  stat_line(lines, "Nulls", stats.nulls)

  metadata_line(lines, "Structure", "h3")
  stat_line(lines, "Max depth", string.format("%d  (%s)", stats.max_depth, label_path(stats.deepest_path, stats.deepest_label, 160)))
  local key_text = tostring(stats.keys)
  if stats.duplicates > 0 then
    key_text = key_text .. string.format(" · %d duplicate", stats.duplicates)
  end
  stat_line(lines, "Keys", key_text)
  if stats.empty_objects > 0 or stats.empty_arrays > 0 then
    stat_line(lines, "Empty", string.format(
      "%d %s · %d %s",
      stats.empty_objects,
      plural(stats.empty_objects, "object", "objects"),
      stats.empty_arrays,
      plural(stats.empty_arrays, "array", "arrays")
    ))
  end
  if stats.largest_object > 0 then
    stat_line(lines, "Largest object", string.format(
      "%d %s (%s)",
      stats.largest_object,
      plural(stats.largest_object, "key", "keys"),
      label_path(stats.largest_object_path, stats.largest_object_label, 140)
    ))
  end
  if stats.largest_array > 0 then
    stat_line(lines, "Largest array", string.format(
      "%d %s (%s)",
      stats.largest_array,
      plural(stats.largest_array, "item", "items"),
      label_path(stats.largest_array_path, stats.largest_array_label, 140)
    ))
  end

  if stats.strings > 0 then
    metadata_line(lines, "Strings", "h3")
    stat_line(lines, "Characters", stats.string_chars)
    stat_line(lines, "Longest", string.format("%d chars (%s)", stats.longest_string, label_path(stats.longest_string_path, stats.longest_string_label, 140)))
  end

  if stats.numbers > 0 then
    metadata_line(lines, "Numbers", "h3")
    stat_line(lines, "Integers", stats.integer_numbers)
    stat_line(lines, "Decimals", stats.decimal_numbers)
    stat_line(lines, "Exponents", stats.exponent_numbers)
    if stats.min_number_raw then
      local range = clip_text(stats.min_number_raw, 40)
      if stats.max_number_raw ~= stats.min_number_raw then
        range = range .. " … " .. clip_text(stats.max_number_raw, 40)
      end
      stat_line(lines, "Range", range)
    end
  end

  if #stats.duplicate_paths > 0 then
    metadata_line(lines, "Duplicate keys", "h3")
    for _, duplicate in ipairs(stats.duplicate_paths) do
      local suffix = ""
      if duplicate.label then
        suffix = duplicate.label .. " · "
      elseif duplicate.line then
        suffix = string.format("line %d · ", duplicate.line)
      end
      metadata_line(lines, "  " .. suffix .. clip_text(duplicate.path, 180), "code")
    end
    if stats.duplicates > #stats.duplicate_paths then
      metadata_line(lines, string.format("  … %d more", stats.duplicates - #stats.duplicate_paths), "muted")
    end
  end

  if #stats.top_keys > 0 then
    metadata_line(lines, analysis.kind == "jsonl" and "First record keys" or "Top-level keys", "h3")
    local shown = {}
    for index, key in ipairs(stats.top_keys) do
      shown[index] = clip_text(encode_string(key), 60)
    end
    metadata_line(lines, "  " .. table.concat(shown, ", "), "code")
  end

  if analysis.truncated then
    metadata_line(lines, "The document is larger than 512 KiB; only the first 512 KiB were analyzed.", "muted")
  end
  return { title = "JSON Metadata", lines = lines }
end

-- ===========================================================================
-- JSONPath
-- ===========================================================================

local MAX_JSONPATH_MATCHES = 4000
local MAX_JSONPATH_DISPLAY = 200

local function jp_fail(state, message, pos)
  error({ jsonpath_error = true, message = message, pos = pos or state.pos }, 0)
end

local function jp_skip_ws(state)
  while state.pos <= state.n do
    local byte = state.text:byte(state.pos)
    if byte == 32 or byte == 9 or byte == 10 or byte == 13 then
      state.pos = state.pos + 1
    else
      break
    end
  end
end

local function jp_parse_quoted(state)
  local quote = state.text:sub(state.pos, state.pos)
  state.pos = state.pos + 1
  local out = {}
  local escapes = {
    n = "\n", t = "\t", r = "\r", b = "\b", f = "\f",
    ["\\"] = "\\", ["'"] = "'", ['"'] = '"',
  }
  while state.pos <= state.n do
    local ch = state.text:sub(state.pos, state.pos)
    if ch == quote then
      state.pos = state.pos + 1
      return table.concat(out)
    elseif ch == "\\" then
      state.pos = state.pos + 1
      if state.pos > state.n then
        jp_fail(state, "Unterminated escape sequence", state.pos - 1)
      end
      local escape = state.text:sub(state.pos, state.pos)
      if escapes[escape] then
        out[#out + 1] = escapes[escape]
        state.pos = state.pos + 1
      elseif escape == "u" then
        local hex = state.text:sub(state.pos + 1, state.pos + 4)
        if #hex < 4 or not hex:match("^%x%x%x%x$") then
          jp_fail(state, "Invalid \\u escape", state.pos + 1)
        end
        out[#out + 1] = utf8.char(tonumber(hex, 16))
        state.pos = state.pos + 5
      else
        jp_fail(state, "Invalid escape sequence '\\" .. escape .. "'", state.pos - 1)
      end
    else
      out[#out + 1] = ch
      state.pos = state.pos + 1
    end
  end
  jp_fail(state, "Unterminated quoted key", state.pos)
end

local function jp_parse_integer(state)
  local start = state.pos
  if state.text:sub(state.pos, state.pos) == "-" then
    state.pos = state.pos + 1
  end
  local digits = state.pos
  while state.pos <= state.n do
    local byte = state.text:byte(state.pos)
    if byte >= 48 and byte <= 57 then
      state.pos = state.pos + 1
    else
      break
    end
  end
  if state.pos == digits then
    state.pos = start
    return nil
  end
  return tonumber(state.text:sub(start, state.pos - 1))
end

local function jp_parse_bracket(state)
  jp_skip_ws(state)
  state.pos = state.pos + 1
  local selectors = {}
  while true do
    jp_skip_ws(state)
    local ch = state.text:sub(state.pos, state.pos)
    if ch == "*" then
      state.pos = state.pos + 1
      selectors[#selectors + 1] = { kind = "wildcard" }
    elseif ch == "'" or ch == '"' then
      selectors[#selectors + 1] = { kind = "name", name = jp_parse_quoted(state) }
    elseif ch == ":" or ch == "-" or (ch >= "0" and ch <= "9") then
      local first = jp_parse_integer(state)
      jp_skip_ws(state)
      if state.text:sub(state.pos, state.pos) == ":" then
        state.pos = state.pos + 1
        jp_skip_ws(state)
        local second = jp_parse_integer(state)
        jp_skip_ws(state)
        local third = nil
        if state.text:sub(state.pos, state.pos) == ":" then
          state.pos = state.pos + 1
          jp_skip_ws(state)
          third = jp_parse_integer(state)
          if third == 0 then
            jp_fail(state, "A slice step cannot be zero", state.pos - 1)
          end
        end
        selectors[#selectors + 1] = { kind = "slice", first = first, second = second, step = third }
      elseif first == nil then
        jp_fail(state, "Expected an array index or a slice", state.pos)
      else
        selectors[#selectors + 1] = { kind = "index", index = first }
      end
    else
      jp_fail(state, "Expected a quoted key, an index, a slice or '*'", state.pos)
    end
    jp_skip_ws(state)
    local separator = state.text:sub(state.pos, state.pos)
    if separator == "," then
      state.pos = state.pos + 1
    elseif separator == "]" then
      state.pos = state.pos + 1
      return selectors
    else
      jp_fail(state, "Expected ',' or ']'", state.pos)
    end
  end
end

local function jp_parse_dot_name(state)
  local start = state.pos
  while state.pos <= state.n do
    local ch = state.text:sub(state.pos, state.pos)
    if ch == "." or ch == "[" or ch == "]" or ch:match("%s") then
      break
    end
    state.pos = state.pos + 1
  end
  if state.pos == start then
    jp_fail(state, "Expected a property name after '.'", state.pos)
  end
  return state.text:sub(start, state.pos - 1)
end

local function parse_jsonpath(expression)
  expression = expression or ""
  local state = { text = expression, pos = 1, n = #expression }
  jp_skip_ws(state)
  if state.text:sub(state.pos, state.pos) ~= "$" then
    jp_fail(state, "JSONPath must start with '$'", state.pos)
  end
  state.pos = state.pos + 1
  local segments = {}
  while true do
    jp_skip_ws(state)
    if state.pos > state.n then
      break
    end
    local ch = state.text:sub(state.pos, state.pos)
    if ch == "[" then
      segments[#segments + 1] = { kind = "child", selectors = jp_parse_bracket(state) }
    elseif ch == "." then
      if state.text:sub(state.pos, state.pos + 1) == ".." then
        state.pos = state.pos + 2
        jp_skip_ws(state)
        local next_ch = state.text:sub(state.pos, state.pos)
        local selectors
        if next_ch == "[" then
          selectors = jp_parse_bracket(state)
        elseif next_ch == "*" then
          state.pos = state.pos + 1
          selectors = { { kind = "wildcard" } }
        else
          selectors = { { kind = "name", name = jp_parse_dot_name(state) } }
        end
        segments[#segments + 1] = { kind = "recursive", selectors = selectors }
      else
        state.pos = state.pos + 1
        if state.text:sub(state.pos, state.pos) == "*" then
          state.pos = state.pos + 1
          segments[#segments + 1] = { kind = "child", selectors = { { kind = "wildcard" } } }
        else
          segments[#segments + 1] = { kind = "child", selectors = { { kind = "name", name = jp_parse_dot_name(state) } } }
        end
      end
    else
      jp_fail(state, "Unexpected character '" .. ch .. "'", state.pos)
    end
  end
  return segments
end

local function add_match(out, seen, node, path, duplicate, limit)
  if #out >= limit then
    return false
  end
  if seen[node] then
    return true
  end
  seen[node] = true
  out[#out + 1] = { node = node, path = path, duplicate = duplicate }
  return true
end

local function apply_selector(node, selector, path, out, seen, limit)
  if node.type == "object" then
    if selector.kind == "name" then
      for _, pair in ipairs(node.pairs) do
        if pair.key == selector.name then
          local duplicate = pair.duplicate_of and pair.index or nil
          if not add_match(out, seen, pair.value, append_key_path(path, pair.key), duplicate, limit) then
            return false
          end
        end
      end
    elseif selector.kind == "wildcard" then
      for _, pair in ipairs(node.pairs) do
        local duplicate = pair.duplicate_of and pair.index or nil
        if not add_match(out, seen, pair.value, append_key_path(path, pair.key), duplicate, limit) then
          return false
        end
      end
    end
    return true
  end
  if node.type == "array" then
    local count = #node.items
    if selector.kind == "index" then
      local index = selector.index
      if index < 0 then
        index = count + index
      end
      if index >= 0 and index < count then
        return add_match(out, seen, node.items[index + 1], append_index_path(path, index), nil, limit)
      end
    elseif selector.kind == "wildcard" then
      for index, item in ipairs(node.items) do
        if not add_match(out, seen, item, append_index_path(path, index - 1), nil, limit) then
          return false
        end
      end
    elseif selector.kind == "slice" then
      local step = selector.step or 1
      local first = selector.first
      local second = selector.second
      local start
      local stop
      if step > 0 then
        start = first or 0
        stop = second or count
        if start < 0 then start = count + start end
        if stop < 0 then stop = count + stop end
        start = math.max(0, start)
        stop = math.min(count, stop)
        for index = start, stop - 1, step do
          if not add_match(out, seen, node.items[index + 1], append_index_path(path, index), nil, limit) then
            return false
          end
        end
      else
        start = first
        stop = second
        if start == nil then start = count - 1 elseif start < 0 then start = count + start end
        if stop == nil then stop = -1 elseif stop < 0 then stop = count + stop end
        start = math.min(count - 1, start)
        stop = math.max(-1, stop)
        for index = start, stop + 1, step do
          if index >= 0 and index < count then
            if not add_match(out, seen, node.items[index + 1], append_index_path(path, index), nil, limit) then
              return false
            end
          end
        end
      end
    end
  end
  return true
end

local function recursive_apply(node, path, selectors, out, seen, limit)
  for _, selector in ipairs(selectors) do
    if not apply_selector(node, selector, path, out, seen, limit) then
      return false
    end
  end
  if node.type == "object" then
    for _, pair in ipairs(node.pairs) do
      local child_path = append_key_path(path, pair.key)
      if not recursive_apply(pair.value, child_path, selectors, out, seen, limit) then
        return false
      end
    end
  elseif node.type == "array" then
    for index, item in ipairs(node.items) do
      if not recursive_apply(item, append_index_path(path, index - 1), selectors, out, seen, limit) then
        return false
      end
    end
  end
  return true
end

local function evaluate_jsonpath(root, segments, limit)
  limit = limit or MAX_JSONPATH_MATCHES
  local matches = { { node = root, path = "$", duplicate = nil } }
  for _, segment in ipairs(segments) do
    local next_matches = {}
    local seen = {}
    local truncated = false
    for _, match in ipairs(matches) do
      local keep_going
      if segment.kind == "child" then
        keep_going = true
        for _, selector in ipairs(segment.selectors) do
          if not apply_selector(match.node, selector, match.path, next_matches, seen, limit) then
            keep_going = false
            truncated = true
            break
          end
        end
      else
        keep_going = recursive_apply(match.node, match.path, segment.selectors, next_matches, seen, limit)
        if not keep_going then
          truncated = true
        end
      end
      if not keep_going then
        break
      end
    end
    matches = next_matches
    if truncated then
      return matches, true
    end
    if #matches == 0 then
      break
    end
  end
  return matches, false
end

local function value_preview(node, budget)
  if node.type == "string" then
    local text, truncated, total = display_string(node.value, budget)
    if truncated then
      text = text .. string.format(" (%d chars)", total)
    end
    return text
  elseif node.type == "number" then
    local raw, truncated = display_number(node.raw)
    if truncated then
      raw = raw .. " (truncated)"
    end
    return raw
  elseif node.type == "boolean" then
    return node.value and "true" or "false"
  elseif node.type == "null" then
    return "null"
  end
  local buffer = {}
  serialize(node, { indent = 0, sort_keys = false, pretty = false }, 0, buffer)
  local text = table.concat(buffer)
  return describe_node(node) .. " · " .. clip_text(text, budget)
end

local function render_jsonpath_error(expression, err)
  local lines = { { text = "Invalid JSONPath", style = "h2" } }
  local message = type(err) == "table" and err.message or tostring(err)
  local pos = type(err) == "table" and err.pos or 1
  metadata_line(lines, message, "text")
  metadata_line(lines, "Expression: " .. clip_text(expression, 300), "muted")
  local shown = clip_text(expression, 300)
  local caret = math.max(0, math.min(pos - 1, #shown))
  metadata_line(lines, string.rep(" ", caret) .. "^", "code")
  return { title = "JSONPath", lines = lines }
end

local function render_jsonpath_results(analysis, expression)
  local ok, segments = pcall(parse_jsonpath, expression)
  if not ok then
    return render_jsonpath_error(expression, segments)
  end
  local results = {}
  local truncated = false
  local display_capped = false
  local total = 0
  if analysis.kind == "json" then
    local matches, cut = evaluate_jsonpath(analysis.root, segments)
    truncated = cut
    for _, match in ipairs(matches) do
      results[#results + 1] = match
    end
    total = #matches
  else
    for _, record in ipairs(analysis.records) do
      local matches, cut = evaluate_jsonpath(record.root, segments)
      truncated = truncated or cut
      for _, match in ipairs(matches) do
        results[#results + 1] = {
          node = match.node,
          path = match.path,
          duplicate = match.duplicate,
          line = record.source_line,
        }
      end
      total = total + #matches
      if #results >= MAX_JSONPATH_DISPLAY then
        display_capped = true
        break
      end
    end
  end
  local lines = { { text = "JSONPath Results", style = "h2" } }
  metadata_line(lines, "Expression  " .. clip_text(expression, 300), "code")
  local match_text = tostring(total)
  if truncated then
    match_text = match_text .. " (capped)"
  elseif display_capped then
    match_text = match_text .. "+ (first " .. MAX_JSONPATH_DISPLAY .. " shown)"
  end
  metadata_line(lines, "Matches     " .. match_text, "muted")
  if total == 0 then
    metadata_line(lines, "No values match this expression.", "muted")
    return { title = "JSONPath", lines = lines }
  end
  local shown = math.min(#results, MAX_JSONPATH_DISPLAY)
  for index = 1, shown do
    local match = results[index]
    local prefix = match.line and string.format("Line %d · ", match.line) or ""
    local path = prefix .. match.path
    if match.duplicate then
      path = path .. string.format(" (duplicate #%d)", match.duplicate)
    end
    metadata_line(
      lines,
      string.format("%d  %s = %s", index, clip_text(path, 220), value_preview(match.node, 160)),
      "code"
    )
  end
  if total > shown then
    metadata_line(lines, string.format("Showing the first %d of %d matches.", shown, total), "muted")
  end
  if truncated then
    metadata_line(lines, string.format("Evaluation stopped after %d matches.", MAX_JSONPATH_MATCHES), "muted")
  end
  return { title = "JSONPath", lines = lines }
end

local function find_jsonpath_match(root, path)
  local ok, segments = pcall(parse_jsonpath, path)
  if not ok then
    return nil, segments
  end
  local matches = evaluate_jsonpath(root, segments, 1)
  return matches[1], nil
end

local function render_path_at(analysis, path, line, type_text, value_text)
  local lines = {}
  local root = analysis.root
  if analysis.kind == "jsonl" then
    for _, record in ipairs(analysis.records) do
      if record.source_line == line then
        root = record.root
        break
      end
    end
    if not root then
      metadata_line(lines, "The cursor is not on a JSON Lines record.", "muted")
      return { title = "JSONPath at Cursor", lines = lines }
    end
  end
  local prefix = (analysis.kind == "jsonl" and line) and string.format("Line %d · ", line) or ""
  metadata_line(lines, "Path   " .. prefix .. clip_text(path, 300), "code")
  if not type_text then
    local match, err = find_jsonpath_match(root, path)
    if not match then
      local message = type(err) == "table" and err.message or "The path no longer resolves."
      metadata_line(lines, message, "muted")
      return { title = "JSONPath at Cursor", lines = lines }
    end
    type_text = describe_node(match.node)
    value_text = value_preview(match.node, 240)
  end
  metadata_line(lines, "Type   " .. type_text, "muted")
  metadata_line(lines, "Value  " .. value_text, "code")
  return { title = "JSONPath at Cursor", lines = lines }
end

-- ===========================================================================
-- Inspector
-- ===========================================================================

local inspector_state = {
  mode = "metadata",
  expression = "",
  path = "$",
  line = nil,
  type_text = nil,
  value_text = nil,
}

local function open_inspector()
  if type(luban) == "table" and type(luban.panel) == "table" and type(luban.panel.open) == "function" then
    local ok, err = luban.panel.open("json.inspector.panel")
    if not ok then
      notify(err or "cannot open the JSON inspector")
    end
  else
    notify("JSON Inspector: open the panel from the Plugins menu")
  end
end

function M.render_inspector(ctx)
  if type(luban) ~= "table" then
    return {
      title = "JSON Inspector",
      lines = { { text = "Plugin host is unavailable.", style = "muted" } },
    }
  end
  local function build()
    local analysis = analysis_document("JSON Inspector")
    if not analysis then
      local doc = active_document()
      if doc then
        local text = normalize_text(type(doc.text) == "string" and doc.text or "")
        local truncated = false
        if #text > MAX_SOURCE_BYTES then
          text = utf8_prefix(text, MAX_SOURCE_BYTES)
          truncated = true
        end
        local ok, root = pcall(parse_json, text)
        if not ok and type(root) == "table" and root.json_error then
          return { title = "JSON Inspector", lines = render_error(text, root, truncated) }
        end
      end
      return {
        title = "JSON Inspector",
        lines = { { text = "The document cannot be analyzed; see the status message.", style = "muted" } },
      }
    end
    if inspector_state.mode == "jsonpath" then
      return render_jsonpath_results(analysis, inspector_state.expression)
    elseif inspector_state.mode == "path" then
      return render_path_at(
        analysis,
        inspector_state.path,
        inspector_state.line,
        inspector_state.type_text,
        inspector_state.value_text
      )
    end
    return render_metadata(analysis)
  end
  local ok, result = pcall(build)
  if not ok then
    if type(luban.log) == "function" then
      luban.log("error", "json inspector failed: " .. tostring(result))
    end
    return {
      title = "JSON Inspector",
      lines = { { text = "Inspector failed: " .. tostring(result), style = "muted" } },
    }
  end
  return result
end

function M.show_metadata(ctx)
  local analysis = analysis_document("JSON: cannot read metadata")
  if not analysis then
    return
  end
  inspector_state.mode = "metadata"
  open_inspector()
  notify("JSON metadata opened in the inspector.")
end

function M.show_jsonpath(ctx)
  local analysis = analysis_document("JSON: cannot read JSONPath")
  if not analysis then
    return
  end
  local starts = compute_line_starts(analysis.text)
  local line = doc_line(analysis.doc)
  local char_index = char_offset_at(analysis.text, line, doc_column(analysis.doc))
  local byte = byte_offset_at(analysis.text, char_index)
  local found = nil
  local record_line = nil
  if analysis.kind == "json" then
    found = locate_node(analysis.root, byte, "$", "$")
  else
    for _, record in ipairs(analysis.records) do
      if record.source_line == line then
        local line_start = starts[line]
        local relative = byte - line_start + 1
        found = locate_node(record.root, relative, "$", "L" .. line .. "$")
        record_line = line
        break
      end
    end
  end
  if not found then
    notify("JSONPath: the cursor is not inside a JSON value.")
    return
  end
  inspector_state.mode = "path"
  inspector_state.path = found.path
  inspector_state.line = record_line
  inspector_state.type_text = describe_node(found.node)
  inspector_state.value_text = value_preview(found.node, 240)
  open_inspector()
  notify("JSONPath: " .. clip_text(found.path, 120))
end

function M.extract_jsonpath(ctx)
  local analysis = analysis_document("JSON: cannot extract JSONPath")
  if not analysis then
    return
  end
  local expression = ""
  local doc = analysis.doc
  if type(doc.selection_start) == "number"
    and type(doc.selection_end) == "number"
    and doc.selection_end > doc.selection_start
  then
    expression = trim(sub_chars(analysis.raw_text, doc.selection_start, doc.selection_end))
  end
  if expression == "" then
    expression = trim(setting_string("jsonpath", ""))
  end
  if expression == "" then
    notify("JSON: select a JSONPath expression or set the 'jsonpath' plugin setting.")
    return
  end
  local ok, err = pcall(parse_jsonpath, expression)
  if not ok then
    local message = type(err) == "table" and err.message or tostring(err)
    local pos = type(err) == "table" and err.pos or 1
    notify(string.format("JSON: invalid JSONPath: %s (column %d)", message, pos))
    return
  end
  inspector_state.mode = "jsonpath"
  inspector_state.expression = expression
  open_inspector()
  notify("JSONPath: " .. clip_text(expression, 100))
end

function M.toggle_fold(ctx)
  local analysis = analysis_document("JSON: cannot fold")
  if not analysis then
    return
  end
  local starts = compute_line_starts(analysis.text)
  local line = doc_line(analysis.doc)
  local char_index = char_offset_at(analysis.text, line, doc_column(analysis.doc))
  local byte = byte_offset_at(analysis.text, char_index)
  local found = nil
  local record_line = nil
  if analysis.kind == "json" then
    found = locate_node(analysis.root, byte, "$", "$")
  else
    for _, record in ipairs(analysis.records) do
      if record.source_line == line then
        found = locate_node(record.root, byte - starts[line] + 1, "$", "L" .. line .. "$")
        record_line = line
        break
      end
    end
  end
  if not found then
    notify("JSON: the cursor is not inside a JSON value.")
    return
  end
  local container = found.containers[#found.containers]
  if not container then
    notify("JSON: the value at the cursor is not an object or an array.")
    return
  end
  ensure_fold_state(analysis.doc, analysis.roots, preview_options().fold_level)
  local path = container.fold_path
  if fold_state.collapsed[path] then
    remove_collapsed(path)
    notify("JSON: expanded " .. clip_text(container.path, 120))
  else
    if not add_collapsed(path) then
      notify("JSON: too many folded nodes.")
      return
    end
    notify("JSON: folded " .. clip_text(container.path, 120))
  end
  M.open_preview(ctx)
end

function M.fold_all(ctx)
  local analysis = analysis_document("JSON: cannot fold")
  if not analysis then
    return
  end
  ensure_fold_state(analysis.doc, analysis.roots, preview_options().fold_level)
  fold_all(analysis.roots)
  M.open_preview(ctx)
  notify(string.format("JSON: folded %d nodes.", fold_state.count))
end

function M.expand_all(ctx)
  local analysis = analysis_document("JSON: cannot expand")
  if not analysis then
    return
  end
  ensure_fold_state(analysis.doc, analysis.roots, preview_options().fold_level)
  expand_all()
  M.open_preview(ctx)
  notify("JSON: expanded all nodes.")
end

function M.open_preview(ctx)
  if type(luban) == "table" and type(luban.panel) == "table" and type(luban.panel.open) == "function" then
    local ok, err = luban.panel.open("json.preview.panel")
    if not ok then
      luban.notify(err or "cannot open the JSON preview")
    end
  else
    luban.notify("JSON Preview: open the panel from the Plugins menu")
  end
end

function M.render_preview(ctx)
  if type(luban) ~= "table" then
    return {
      title = "JSON Preview",
      lines = { { text = "Plugin host is unavailable.", style = "muted" } },
    }
  end
  local doc = active_document()
  if not doc then
    return {
      title = "JSON Preview",
      lines = { { text = "Preview is not available for this document.", style = "muted" } },
    }
  end
  local opts = preview_options()
  local ok, result = pcall(render_document, doc, opts)
  if not ok then
    if type(luban.log) == "function" then
      luban.log("error", "json preview failed: " .. tostring(result))
    end
    return {
      title = "JSON Preview",
      lines = { { text = "Preview failed: " .. tostring(result), style = "muted" } },
    }
  end
  return result
end

function M.format_document(ctx)
  local text, root = prepare_document("JSON: cannot format")
  if not text then
    return
  end
  local indent = setting_int("indent", 2, 1, 8)
  local output = serialize_document(root, {
    indent = indent,
    sort_keys = false,
    pretty = true,
  })
  if not update_document("JSON: cannot format", output) then
    return
  end
  local duplicates = count_duplicates(root)
  local message = "JSON formatted (" .. describe_node(root)
  if duplicates > 0 then
    message = message .. ", " .. duplicates .. " " .. plural(duplicates, "duplicate key", "duplicate keys")
  end
  notify(message .. ").")
end

function M.minify_document(ctx)
  local text, root = prepare_document("JSON: cannot minify")
  if not text then
    return
  end
  local output = serialize_document(root, {
    indent = 0,
    sort_keys = false,
    pretty = false,
  })
  if not update_document("JSON: cannot minify", output) then
    return
  end
  local duplicates = count_duplicates(root)
  local message = string.format("JSON minified (%s → %s", format_bytes(#text), format_bytes(#output))
  if duplicates > 0 then
    message = message .. ", " .. duplicates .. " " .. plural(duplicates, "duplicate key", "duplicate keys")
  end
  notify(message .. ").")
end

function M.validate_document(ctx)
  local text, root = prepare_document("JSON: cannot validate")
  if not text then
    return
  end
  local duplicates = count_duplicates(root)
  local message = "JSON is valid: " .. describe_node(root)
  if duplicates > 0 then
    message = message .. " (" .. duplicates .. " " .. plural(duplicates, "duplicate key", "duplicate keys") .. ")"
  end
  notify(message .. ".")
end

function M.activate(ctx)
  if type(luban.log) == "function" then
    luban.log("info", "JSON Preview activated")
  end
end

M._internals = {
  parse_json = parse_json,
  serialize_document = serialize_document,
  describe_node = describe_node,
  normalize_text = normalize_text,
  compute_line_starts = compute_line_starts,
  locate = locate,
  display_string = display_string,
  encode_string = encode_string,
  format_bytes = format_bytes,
  count_duplicates = count_duplicates,
  append_key_path = append_key_path,
  locate_node = locate_node,
  char_offset_at = char_offset_at,
  byte_offset_at = byte_offset_at,
  sub_chars = sub_chars,
  ensure_fold_state = ensure_fold_state,
  fold_state = fold_state,
  parse_jsonpath = parse_jsonpath,
  evaluate_jsonpath = evaluate_jsonpath,
  new_stats = new_stats,
  collect_stats = collect_stats,
  render_metadata = render_metadata,
  render_jsonpath_results = render_jsonpath_results,
  render_path_at = render_path_at,
  analysis_document = analysis_document,
  inspector_state = inspector_state,
}

return M
