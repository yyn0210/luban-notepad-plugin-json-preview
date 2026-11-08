-- Strict RFC 8259 JSON parser for the JSON Preview plugin.
--
-- Split out of the 1.x main.lua; the parser bodies are unchanged. Key order
-- and duplicate keys are preserved, every node carries its source range and
-- `\uXXXX` escapes and surrogate pairs decode exactly as before.
--
-- Errors are raised as table objects `{ json_error = true, message, pos }`
-- (not strings), so callers can pcall and render a source excerpt.

local M = {}

local MAX_DEPTH = 256

-- ===========================================================================
-- Parser
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

M.MAX_DEPTH = MAX_DEPTH
M.parse = parse_json
M.compute_line_starts = compute_line_starts
M.line_number_at = line_number_at
M.locate = locate

return M
