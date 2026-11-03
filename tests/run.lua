-- Standalone tests for main.lua (Lua 5.4).
--
-- Run from the repository root:
--   lua5.4 tests/run.lua
--
-- The harness supplies the same `luban` surface the host exposes. It never
-- runs inside the app sandbox, so `os` and `io` are available here only.

local PLUGIN_MAIN = os.getenv("PLUGIN_MAIN") or "main.lua"

local current_doc = nil
local current_settings = {}
local notifications = {}
local updated_text = nil
local update_result = true

local function reset_luban()
  current_doc = nil
  current_settings = {}
  notifications = {}
  updated_text = nil
  update_result = true
  luban = {
    log = function(level, message) end,
    notify = function(message)
      notifications[#notifications + 1] = message
    end,
    get_document = function()
      return current_doc
    end,
    set_document_text = function(text)
      updated_text = text
      if update_result then
        return true
      end
      return false, "update failed"
    end,
    settings = {
      get = function(key)
        return current_settings[key]
      end,
    },
    panel = {
      open = function(id)
        notifications[#notifications + 1] = "open:" .. id
        return true
      end,
    },
  }
end

reset_luban()

local ok, plugin = pcall(loadfile(PLUGIN_MAIN))
assert(ok and type(plugin) == "table", "cannot load " .. PLUGIN_MAIN .. ": " .. tostring(plugin))
local M = plugin
local I = M._internals

local PASSED = 0
local FAILED = 0
local CURRENT = ""

local function fail(message)
  error(message, 2)
end

local function eq(actual, expected, message)
  if actual ~= expected then
    fail((message or "values differ") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
  end
end

local function truthy(value, message)
  if not value then
    fail(message or "expected a truthy value")
  end
end

local function contains(text, needle, message)
  if type(text) ~= "string" or not text:find(needle, 1, true) then
    fail((message or "missing substring") .. ": " .. tostring(needle) .. " in " .. tostring(text))
  end
end

local function test(name, fn)
  CURRENT = name
  local ok_run, error_message = pcall(fn)
  if ok_run then
    PASSED = PASSED + 1
    io.write("ok   ", name, "\n")
  else
    FAILED = FAILED + 1
    io.write("FAIL ", name, "\n     ", tostring(error_message), "\n")
  end
end

local function check_panel(panel)
  truthy(type(panel) == "table", "panel is not a table")
  truthy(type(panel.lines) == "table", "panel.lines is not a table")
  truthy(#panel.lines > 0, "panel has no lines")
  if #panel.lines > 5000 then
    fail("panel has more than 5000 lines")
  end
  local allowed = {
    text = true, muted = true, h1 = true, h2 = true, h3 = true, h4 = true,
    h5 = true, h6 = true, code = true, quote = true, list = true,
    table = true, rule = true,
  }
  for index, line in ipairs(panel.lines) do
    truthy(type(line.text) == "string", "line " .. index .. " text is not a string")
    if #line.text > 4096 then
      fail("line " .. index .. " is longer than 4096 bytes")
    end
    if line.style ~= nil then
      truthy(allowed[line.style], "line " .. index .. " has unknown style " .. tostring(line.style))
    end
    if line.indent ~= nil then
      truthy(line.indent >= 0 and line.indent <= 8, "line " .. index .. " indent out of range")
    end
    if line.spans then
      truthy(#line.spans <= 512, "line " .. index .. " has too many spans")
      local parts = {}
      for _, span in ipairs(line.spans) do
        truthy(type(span.text) == "string", "line " .. index .. " span text is not a string")
        parts[#parts + 1] = span.text
      end
      eq(table.concat(parts), line.text, "line " .. index .. " spans do not match text")
    end
  end
end

local function render(text, settings)
  current_doc = { path = "/tmp/test.json", language = "JSON", text = text }
  current_settings = settings or {}
  notifications = {}
  local panel = M.render_preview({})
  check_panel(panel)
  return panel
end

local function line_texts(panel)
  local texts = {}
  for _, line in ipairs(panel.lines) do
    texts[#texts + 1] = line.text
  end
  return texts
end

local function index_of(panel, needle)
  for index, line in ipairs(panel.lines) do
    if line.text:find(needle, 1, true) then
      return index
    end
  end
  return nil
end

local function role_has(line, role, text)
  for _, span in ipairs(line.spans or {}) do
    if (not text or span.text == text) and span.role == role then
      return true
    end
  end
  return false
end

local function parse(text)
  local ok_parse, result = pcall(I.parse_json, text)
  if not ok_parse then
    return nil, result
  end
  return result
end

local function compact(text)
  local node = assert(parse(text))
  return I.serialize_document(node, { indent = 0, sort_keys = false, pretty = false })
end

local function expect_error(text, needle)
  local node, err = parse(text)
  truthy(node == nil, "expected a parse error")
  truthy(type(err) == "table" and err.json_error, "expected a JSON error table")
  contains(err.message, needle, "unexpected error message")
  return err
end

-- ---------------------------------------------------------------------------

test("parses scalars, arrays and objects while preserving key order", function()
  eq(compact("null"), "null")
  eq(compact(" true "), "true")
  eq(compact("false"), "false")
  eq(compact(" 42 "), "42")
  eq(compact('"text"'), '"text"')
  eq(compact('{"b":2,"a":1}'), '{"b":2,"a":1}', "key order changed")
  eq(compact("[1,2,[3,{}],[]]"), "[1,2,[3,{}],[]]")
  eq(compact("[]"), "[]")
  eq(compact("{}"), "{}")
end)

test("decodes escapes, unicode and surrogate pairs", function()
  eq(compact('"a\\nb\\t\\"c\\"\\\\d\\/e"'), '"a\\nb\\t\\"c\\"\\\\d/e"')
  eq(compact('"\\u00e9"'), '"é"')
  eq(compact('"\\u4e2d\\u6587"'), '"中文"')
  eq(compact('"\\ud83d\\ude00"'), '"' .. utf8.char(0x1F600) .. '"')
  eq(compact('"\\uD83D\\uDE00"'), '"' .. utf8.char(0x1F600) .. '"')
  eq(compact('"\\u0001"'), '"\\u0001"')
  eq(compact('"\\u001f"'), '"\\u001F"')
end)

test("keeps valid number literals exactly as written", function()
  eq(compact("[-0,0,0.0,1.5,1e10,-2.5E-3,1E+2]"), "[-0,0,0.0,1.5,1e10,-2.5E-3,1E+2]")
end)

test("rejects malformed numbers", function()
  expect_error("01", "Leading zeros")
  expect_error("-01", "Leading zeros")
  expect_error("1.", "decimal point")
  expect_error(".5", "Unexpected character")
  expect_error("+1", "Unexpected character")
  expect_error("1e", "exponent")
  expect_error("1e+", "exponent")
  expect_error("NaN", "Unexpected character")
  expect_error("Infinity", "Unexpected character")
end)

test("rejects malformed JSON with useful messages", function()
  expect_error("", "empty")
  expect_error('{"a":1,}', "Trailing comma")
  expect_error("[1,]", "Trailing comma")
  expect_error('{"a":1 // x\n}', "Comments are not allowed")
  expect_error("{'a':1}", "Single-quoted")
  expect_error('{"a" 1}', "Expected ':'")
  expect_error('{"a": "x}', "Unterminated string")
  expect_error('"a\1b"', "Unescaped control character")
  expect_error('"\\x"', "Invalid escape")
  expect_error('"\\u12"', "Invalid \\u escape")
  expect_error('"\\ud800"', "Unpaired high surrogate")
  expect_error('"\\udc00"', "Unpaired low surrogate")
  expect_error("{} {}", "Unexpected trailing content")
  expect_error("{\"a\":1} trailing", "Unexpected trailing content")
end)

test("enforces a 256-level nesting limit", function()
  local allowed = string.rep("[", 256) .. string.rep("]", 256)
  truthy(parse(allowed) ~= nil, "256 levels must parse")
  local denied = string.rep("[", 257) .. string.rep("]", 257)
  expect_error(denied, "Maximum nesting depth of 256")
end)

test("preserves duplicate keys and counts them", function()
  local node = assert(parse('{"a":1,"a":2,"b":3}'))
  eq(#node.pairs, 3, "duplicate key was lost")
  eq(node.duplicates, 1, "duplicate count")
  truthy(node.pairs[2].duplicate_of == node.pairs[1], "duplicate link missing")
end)

test("renders a tree with theme roles and a summary", function()
  local panel = render('{"name":"x","count":2,"ok":true,"nothing":null,"items":[1]}')
  contains(panel.lines[1].text, "Object · 5 keys")
  local key_line = panel.lines[index_of(panel, '"name"')]
  truthy(role_has(key_line, "property", '"name"'), "key role missing")
  truthy(role_has(key_line, "string", '"x"'), "string role missing")
  local number_line = panel.lines[index_of(panel, '"count"')]
  truthy(role_has(number_line, "number", "2"), "number role missing")
  local boolean_line = panel.lines[index_of(panel, '"ok"')]
  truthy(role_has(boolean_line, "boolean", "true"), "boolean role missing")
  local null_line = panel.lines[index_of(panel, '"nothing"')]
  truthy(role_has(null_line, "constant", "null"), "null role missing")
  truthy(index_of(panel, '"items": [') ~= nil, "array opening line missing")
  truthy(index_of(panel, "]") ~= nil, "array closing line missing")
end)

test("sorts keys in the preview when asked", function()
  local panel = render('{"b":1,"a":2}', { sort_keys = true })
  local a = index_of(panel, '"a"')
  local b = index_of(panel, '"b"')
  truthy(a and b and a < b, "keys were not sorted")
  local unsorted = render('{"b":1,"a":2}')
  local a2 = index_of(unsorted, '"a"')
  local b2 = index_of(unsorted, '"b"')
  truthy(a2 and b2 and b2 < a2, "original order was not preserved")
end)

test("marks duplicate keys in the preview", function()
  local panel = render('{\n  "a": 1,\n  "a": 2\n}')
  local line = panel.lines[index_of(panel, '"a": 2')]
  truthy(line, "duplicate line missing")
  contains(line.text, "duplicate key")
  contains(line.text, "first at line 2")
end)

test("formats the document with the configured indent and original order", function()
  current_doc = { path = "/tmp/test.json", text = '{"b":1,"a":[true,null]}' }
  current_settings = { indent = 4, sort_keys = true }
  notifications = {}
  M.format_document({})
  eq(updated_text, '{\n    "b": 1,\n    "a": [\n        true,\n        null\n    ]\n}\n')
  contains(notifications[#notifications], "JSON formatted")
  contains(notifications[#notifications], "Object · 2 keys")
end)

test("minifies the document", function()
  current_doc = { path = "/tmp/test.json", text = '{\n  "b": 1,\n  "a": [ true, null ]\n}\n' }
  current_settings = {}
  notifications = {}
  M.minify_document({})
  eq(updated_text, '{"b":1,"a":[true,null]}')
  contains(notifications[#notifications], "JSON minified")
end)

test("format reports parse errors and does not replace the document", function()
  current_doc = { path = "/tmp/test.json", text = '{"a": 1,}' }
  current_settings = {}
  notifications = {}
  updated_text = nil
  M.format_document({})
  eq(updated_text, nil, "document was replaced despite an error")
  contains(notifications[#notifications], "Trailing comma")
  contains(notifications[#notifications], "line 1, column 9")
end)

test("format reports update failures", function()
  current_doc = { path = "/tmp/test.json", text = '{"a":1}' }
  update_result = false
  notifications = {}
  M.format_document({})
  truthy(notifications[#notifications]:find("update failed", 1, true) ~= nil, "update error missing")
  update_result = true
end)

test("validate reports valid and invalid documents", function()
  current_doc = { path = "/tmp/test.json", text = '{"a":1}' }
  notifications = {}
  M.validate_document({})
  contains(notifications[#notifications], "JSON is valid")
  contains(notifications[#notifications], "Object · 1 key")
  current_doc = { path = "/tmp/test.json", text = '{"a":}' }
  notifications = {}
  M.validate_document({})
  contains(notifications[#notifications], "cannot validate")
  contains(notifications[#notifications], "line 1, column 6")
end)

test("shows invalid JSON with a source excerpt and caret", function()
  local panel = render('{\n  "a": 1,\n  "b": \n}\n')
  contains(panel.lines[1].text, "Invalid JSON")
  contains(panel.lines[2].text, "at line 4, column 1")
  truthy(index_of(panel, "4 | }") ~= nil, "error line missing from excerpt")
  local caret
  for _, line in ipairs(panel.lines) do
    if line.text:find("%^") then
      caret = line.text
    end
  end
  truthy(caret, "caret line missing")
  contains(caret, "| ^")
end)

test("long error lines are windowed around the caret", function()
  local prefix = string.rep("x", 500)
  local panel = render('{"a": "' .. prefix .. '" "b"}\n')
  for _, line in ipairs(panel.lines) do
    truthy(#line.text <= 4096, "error line escaped the cap")
  end
  contains(panel.lines[1].text, "Invalid JSON")
  local caret
  local windowed = false
  for _, line in ipairs(panel.lines) do
    if line.text:find("…", 1, true) then
      windowed = true
    end
    if line.text:find("%^") then
      caret = line.text
    end
  end
  truthy(windowed, "long error line was not windowed")
  truthy(caret, "caret line missing")
end)

test("normalizes CRLF and a UTF-8 BOM", function()
  local panel = render("\239\187\191{\r\n  \"a\": 1\r\n}\r\n")
  contains(panel.lines[1].text, "Object · 1 key")
  truthy(index_of(panel, '"a": 1') ~= nil, "value missing")
end)

test("detects JSON Lines when every non-empty line is valid", function()
  local panel = render('{"a":1}\n{"b":[2,3]}\n\n{"c":true}\n')
  contains(panel.lines[1].text, "JSON Lines · 3 records")
  truthy(index_of(panel, "Line 1 · Object · 1 key") ~= nil, "record 1 header missing")
  truthy(index_of(panel, "Line 2 · Object · 1 key") ~= nil, "record 2 header missing")
  truthy(index_of(panel, "Line 4 · Object · 1 key") ~= nil, "record 3 header missing")
end)

test("JSON Lines support can be disabled", function()
  local panel = render('{"a":1}\n{"b":2}\n', { json_lines = false })
  contains(panel.lines[1].text, "Invalid JSON")
  truthy(index_of(panel, "JSON Lines") == nil, "JSON Lines should be disabled")
end)

test("a malformed JSON Lines document falls back to the whole-document error", function()
  local panel = render('{"a":1}\n{"b":}\n')
  contains(panel.lines[1].text, "Invalid JSON")
  truthy(index_of(panel, "JSON Lines") == nil, "partial JSON Lines was accepted")
end)

test("long strings are truncated with a character count", function()
  local long = string.rep("x", 5000)
  local panel = render('{"s":"' .. long .. '"}')
  local line = panel.lines[index_of(panel, '"s"')]
  truthy(line, "string line missing")
  truthy(#line.text < 5000, "long string was not truncated")
  contains(line.text, "5000 chars total")
end)

test("source over 512 KiB is truncated with a notice", function()
  local panel = render('{"a":"' .. string.rep("x", 520 * 1024) .. '"}')
  local last = panel.lines[#panel.lines]
  contains(last.text, "512 KiB")
end)

test("large arrays stop at the render line cap", function()
  local chunks = { "[" }
  for index = 1, 5000 do
    chunks[#chunks + 1] = (index > 1 and "," or "") .. tostring(index)
  end
  chunks[#chunks + 1] = "]"
  local panel = render(table.concat(chunks))
  truthy(#panel.lines <= 4001, "render line cap exceeded")
  contains(panel.lines[#panel.lines].text, "first 4000 lines")
end)

test("empty and unsupported documents explain themselves", function()
  local empty = render("")
  contains(empty.lines[1].text, "empty")
  current_doc = nil
  current_settings = {}
  notifications = {}
  local panel = M.render_preview({})
  check_panel(panel)
  contains(panel.lines[1].text, "not available")
end)

test("the command opens the declared panel, with a menu fallback on old hosts", function()
  notifications = {}
  M.open_preview({})
  eq(notifications[#notifications], "open:json.preview.panel")
  local original = luban.panel
  luban.panel = nil
  notifications = {}
  M.open_preview({})
  contains(notifications[#notifications], "Plugins menu")
  luban.panel = original
end)

test("the rich fixture keeps every invariant", function()
  local file = assert(io.open("tests/fixtures/complex.json", "rb"))
  local text = file:read("*a")
  file:close()
  local panel = render(text)
  truthy(#panel.lines > 20, "fixture produced too few lines")
  contains(panel.lines[1].text, "Object")
  truthy(index_of(panel, '"users"') ~= nil, "fixture users missing")
  truthy(index_of(panel, '"roles"') ~= nil, "fixture roles missing")
end)

io.write(string.format("\n%d passed, %d failed\n", PASSED, FAILED))
if FAILED > 0 then
  os.exit(1)
end
