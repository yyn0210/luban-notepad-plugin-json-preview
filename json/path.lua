-- Path building, node location and JSONPath for the JSON Preview plugin.
--
-- Split out of the 1.x main.lua. Two path flavours exist:
--
-- * Display paths (JSONPath shown in the UI, metadata, extraction) keep the
--   bounded `shorten_path` treatment: very deep documents would otherwise
--   build paths quadratic in the source size, so anything over 2 KiB is
--   prefix + suffix hash.
-- * Fold paths identify collapsed nodes in the in-memory fold state. They are
--   plain strings with no cap and no hashing: the state is a plain table
--   keyed by the exact structural path, so folding stays reliable for any
--   path the parser can produce (depth is capped at 256 by the parser).

local D = require("json.display")
local P = require("json.parser")

local M = {}

local MAX_PATH_BYTES = 2048
local MAX_JSONPATH_MATCHES = 4000
local MAX_JSONPATH_DISPLAY = 200

-- ===========================================================================
-- Path building
-- ===========================================================================

local encode_string = D.encode_string
local utf8_prefix = D.utf8_prefix

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

-- Display paths keep the bounded treatment above.
local function append_key_path(path, key)
  if is_identifier(key) then
    return shorten_path(path .. "." .. key)
  end
  return shorten_path(path .. "[" .. encode_string(key) .. "]")
end

local function append_index_path(path, index)
  return shorten_path(path .. "[" .. index .. "]")
end

-- Fold paths are exact: no shortening, no hashing.
local function append_key_fold_path(path, key)
  if is_identifier(key) then
    return path .. "." .. key
  end
  return path .. "[" .. encode_string(key) .. "]"
end

local function append_index_fold_path(path, index)
  return path .. "[" .. index .. "]"
end

-- Paths used for display (JSONPath) and for fold identity. Duplicate object
-- keys share a display path, so their fold path also carries the pair index.
local function child_paths(path, fold_path, pair)
  local display = append_key_path(path, pair.key)
  local fold = append_key_fold_path(fold_path, pair.key)
  if pair.duplicate_of then
    fold = fold .. "#" .. pair.index
  end
  return display, fold
end

local function array_child_paths(path, fold_path, index)
  return append_index_path(path, index), append_index_fold_path(path, index)
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

-- ===========================================================================
-- Document positions
-- ===========================================================================

local compute_line_starts = P.compute_line_starts

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
-- JSONPath
-- ===========================================================================

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

M.append_key_path = append_key_path
M.append_index_path = append_index_path
M.child_paths = child_paths
M.array_child_paths = array_child_paths
M.walk_containers = walk_containers
M.locate_node = locate_node
M.char_offset_at = char_offset_at
M.byte_offset_at = byte_offset_at
M.sub_chars = sub_chars
M.parse_jsonpath = parse_jsonpath
M.evaluate_jsonpath = evaluate_jsonpath
M.MAX_JSONPATH_MATCHES = MAX_JSONPATH_MATCHES
M.MAX_JSONPATH_DISPLAY = MAX_JSONPATH_DISPLAY

return M
