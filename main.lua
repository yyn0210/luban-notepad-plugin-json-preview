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
  return { type = "number", raw = text:sub(start, parser.pos - 1) }
end

local function parse_literal(parser)
  local text = parser.text
  local pos = parser.pos
  if text:sub(pos, pos + 3) == "true" then
    parser.pos = pos + 4
    return { type = "boolean", value = true }
  elseif text:sub(pos, pos + 4) == "false" then
    parser.pos = pos + 5
    return { type = "boolean", value = false }
  elseif text:sub(pos, pos + 3) == "null" then
    parser.pos = pos + 4
    return { type = "null" }
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
    return { type = "object", pairs = pairs, duplicates = 0 }
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
      return { type = "object", pairs = pairs, duplicates = duplicates }
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
    return { type = "array", items = items }
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
      return { type = "array", items = items }
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
    return { type = "string", value = parse_string(parser), start = start }
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

render_value = function(renderer, node, depth, prefix, suffix, notes, opts, line_for_pos)
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
      return push_line(renderer, finish_line(tokens, notes))
    end
    tokens[#tokens + 1] = { text = "{", role = "punctuation.bracket" }
    if not push_line(renderer, finish_line(tokens, notes)) then
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
      if not render_value(renderer, pair.value, depth + 1, child_prefix, child_suffix, pair_notes, opts, line_for_pos) then
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
      return push_line(renderer, finish_line(tokens, notes))
    end
    tokens[#tokens + 1] = { text = "[", role = "punctuation.bracket" }
    if not push_line(renderer, finish_line(tokens, notes)) then
      return false
    end
    for index, item in ipairs(node.items) do
      local child_suffix = index < #node.items and "," or ""
      if not render_value(renderer, item, depth + 1, {}, child_suffix, nil, opts, line_for_pos) then
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
  local value_notes = notes or {}
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
  return push_line(renderer, finish_line(tokens, value_notes))
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

local function render_valid(text, root, opts)
  local renderer = { lines = {}, count = 0, overflow = false }
  local duplicates = count_duplicates(root)
  local summary = describe_node(root) .. " · " .. format_bytes(#text)
  if duplicates > 0 then
    summary = summary .. " · " .. duplicates .. " " .. plural(duplicates, "duplicate key", "duplicate keys")
  end
  push_line(renderer, { text = summary, style = "muted" })
  local starts = compute_line_starts(text)
  local function line_for_pos(pos)
    return line_number_at(starts, pos)
  end
  render_value(renderer, root, 0, {}, "", nil, opts, line_for_pos)
  if renderer.overflow then
    renderer.lines[#renderer.lines + 1] = {
      text = string.format("Preview truncated: showing the first %d lines.", MAX_RENDER_LINES),
      style = "muted",
    }
  end
  return renderer.lines
end

local function render_json_lines(text, records, opts)
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
    if not render_value(renderer, record.root, 0, {}, "", nil, opts, line_for_pos) then
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
    local lines = render_valid(text, root, opts)
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
      return { title = document_title(doc), lines = render_json_lines(text, records, opts) }
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

local function preview_options()
  local indent = setting_int("indent", 2, 1, 8)
  return {
    indent = indent,
    sort_keys = setting_bool("sort_keys", false),
    json_lines = setting_bool("json_lines", true),
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
}

return M
