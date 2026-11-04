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
local updated_selection = nil
local update_result = true

local function reset_luban()
  current_doc = nil
  current_settings = {}
  notifications = {}
  updated_text = nil
  updated_selection = nil
  update_result = true
  luban = {
    log = function(level, message) end,
    notify = function(message)
      notifications[#notifications + 1] = message
    end,
    get_document = function()
      return current_doc
    end,
    set_document_text = function(text, start, finish)
      updated_text = text
      updated_selection = { start, finish }
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

local function reset_folds()
  I.fold_state.doc_key = nil
  I.fold_state.signature = nil
  I.fold_state.level = nil
  for path in pairs(I.fold_state.collapsed) do
    I.fold_state.collapsed[path] = nil
  end
  I.fold_state.count = 0
  I.fold_state.seeded = false
end

local function render(text, settings, keep_folds)
  if not keep_folds then
    reset_folds()
  end
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
  contains(panel.title, "Object · 5 keys", "summary missing from title")
  local key_line = panel.lines[index_of(panel, '"name"')]
  truthy(role_has(key_line, "property", '"name"'), "key role missing")
  truthy(role_has(key_line, "string", '"x"'), "string role missing")
  local number_line = panel.lines[index_of(panel, '"count"')]
  truthy(role_has(number_line, "number", "2"), "number role missing")
  local boolean_line = panel.lines[index_of(panel, '"ok"')]
  truthy(role_has(boolean_line, "boolean", "true"), "boolean role missing")
  local null_line = panel.lines[index_of(panel, '"nothing"')]
  truthy(role_has(null_line, "constant", "null"), "null role missing")
  truthy(index_of(panel, '"items": ') ~= nil, "array opening line missing")
  truthy(index_of(panel, '▾ "items": [') ~= nil, "array fold marker missing")
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
  truthy(updated_selection[1] == 0 and updated_selection[2] == 0, "cursor should move to the document start")
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
  contains(panel.title, "Object · 1 key", "summary missing from title")
  truthy(index_of(panel, '"a": 1') ~= nil, "value missing")
end)

test("detects JSON Lines when every non-empty line is valid", function()
  local panel = render('{"a":1}\n{"b":[2,3]}\n\n{"c":true}\n')
  contains(panel.title, "JSON Lines · 3 records", "summary missing from title")
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

local function any_notification(needle)
  for _, message in ipairs(notifications) do
    if message:find(needle, 1, true) then
      return true
    end
  end
  return false
end

test("puts preview actions in the panel toolbar, not the Plugins menu", function()
  local file = assert(io.open("plugin.json", "rb"))
  local text = file:read("*a")
  file:close()
  for _, id in ipairs({
    "json.fold.toggle",
    "json.fold.all",
    "json.fold.none",
    "json.fold.toggle-all",
    "json.path.show",
    "json.path.extract",
    "json.path.action",
    "json.metadata",
  }) do
    contains(text, '"id": "' .. id .. '"', "missing command " .. id)
  end
  local menu_start = assert(text:find('"menus"', 1, true))
  local menu_end = assert(text:find("]", menu_start, true))
  local menus = text:sub(menu_start, menu_end)
  for _, id in ipairs({
    "json.fold.toggle",
    "json.fold.all",
    "json.fold.none",
    "json.path.show",
    "json.path.extract",
    "json.metadata",
  }) do
    truthy(not menus:find('"' .. id .. '"', 1, true), "feature command should not be in the Plugins menu: " .. id)
  end
  contains(menus, '"json.preview"', "preview menu entry missing")
end)

test("renders the three action rows and toggles all folds", function()
  local text = '{"a":{"b":1},"c":[1,2]}'
  local panel = render(text)
  eq(panel.lines[1].command, "json.fold.all")
  contains(panel.lines[1].text, "[ Fold All ]")
  eq(panel.lines[2].command, "json.path.action")
  contains(panel.lines[2].text, "[ Show / Extract ]")
  eq(panel.lines[3].command, "json.metadata")
  contains(panel.lines[3].text, "[ Analyze ]")
  eq(panel.lines[4].style, "rule")
  current_doc = {
    path = "/tmp/test.json",
    text = text,
    line = 1,
    column = 6,
    selection_start = 0,
    selection_end = 0,
  }
  notifications = {}
  M.toggle_all_folds({})
  truthy(any_notification("folded 2 nodes"), "toggle-all fold notification missing")
  local folded = M.render_preview({})
  contains(folded.lines[1].text, "[ Expand All ]")
  eq(folded.lines[1].command, "json.fold.none")
  truthy(index_of(folded, '▸ "a": { … 1 key }') ~= nil, "nested node was not folded")
  M.toggle_all_folds({})
  local expanded = M.render_preview({})
  contains(expanded.lines[1].text, "[ Fold All ]")
  truthy(index_of(expanded, "▸") == nil, "toggle-all did not expand")
end)

test("uses compact header actions on hosts with panel API version 2", function()
  local original = luban.panel
  local ok, err = pcall(function()
    luban.panel = { open = original.open, version = 2 }
    local text = '{"a":{"b":1},"c":[1,2]}'
    reset_folds()
    current_doc = {
      path = "/tmp/actions.json",
      text = text,
      line = 1,
      column = 1,
      selection_start = 0,
      selection_end = 0,
    }
    current_settings = {}
    local panel = M.render_preview({})
    check_panel(panel)
    eq(panel.lines[1].style, "rule")
    truthy(panel.actions ~= nil, "panel actions missing")
    eq(#panel.actions, 3)
    eq(panel.actions[1].label, "Fold All")
    eq(panel.actions[1].command, "json.fold.toggle-all")
    eq(panel.actions[2].command, "json.path.action")
    eq(panel.actions[3].command, "json.metadata")
    truthy(index_of(panel, "[ Fold All ]") == nil, "fallback toolbar should be omitted")
    truthy(index_of(panel, '▾ "a": {') ~= nil, "tree missing")
    M.toggle_all_folds({})
    local folded = M.render_preview({})
    check_panel(folded)
    eq(folded.actions[1].label, "Expand All")
    truthy(index_of(folded, '▸ "a": { … 1 key }') ~= nil, "action fold missing")
  end)
  luban.panel = original
  if not ok then
    error(err)
  end
end)

test("the toolbar JSONPath action follows the editor selection", function()
  local expression = "$.users[0].name"
  local text = '{"query":"' .. expression .. '","users":[{"name":"Ada"}]}'
  local byte_start = assert(text:find(expression, 1, true))
  local start_char = utf8.len(text:sub(1, byte_start - 1))
  current_doc = {
    path = "/tmp/action.json",
    text = text,
    line = 1,
    column = 1,
    selection_start = start_char,
    selection_end = start_char + #expression,
  }
  current_settings = {}
  notifications = {}
  M.jsonpath_action({})
  eq(I.inspector_state.mode, "jsonpath")
  eq(I.inspector_state.expression, expression)
  local starts = I.compute_line_starts(text)
  local position = assert(text:find("Ada", 1, true))
  local location = I.locate(text, starts, position)
  current_doc.selection_start = 0
  current_doc.selection_end = 0
  current_doc.line = location.line
  current_doc.column = location.column
  notifications = {}
  M.jsonpath_action({})
  eq(I.inspector_state.mode, "path")
  eq(I.inspector_state.path, "$.users[0].name")
end)

test("the rich fixture keeps every invariant", function()
  local file = assert(io.open("tests/fixtures/complex.json", "rb"))
  local text = file:read("*a")
  file:close()
  local panel = render(text)
  truthy(#panel.lines > 20, "fixture produced too few lines")
  contains(panel.title, "Object", "summary missing from title")
  truthy(index_of(panel, '"users"') ~= nil, "fixture users missing")
  truthy(index_of(panel, '"roles"') ~= nil, "fixture roles missing")
end)

test("folds and expands the node containing the cursor", function()
  local text = '{\n  "a": {\n    "b": 1\n  },\n  "c": [1, 2]\n}'
  local panel = render(text)
  truthy(index_of(panel, "▾ {") ~= nil, "root fold marker missing")
  current_doc = {
    path = "/tmp/test.json",
    language = "JSON",
    text = text,
    line = 2,
    column = 8,
    selection_start = 0,
    selection_end = 0,
  }
  notifications = {}
  M.toggle_fold({})
  truthy(any_notification("folded $.a"), "fold notification missing")
  local folded = M.render_preview({})
  check_panel(folded)
  truthy(index_of(folded, '▸ "a": { … 1 key }') ~= nil, "collapsed line missing")
  notifications = {}
  M.toggle_fold({})
  truthy(any_notification("expanded $.a"), "expand notification missing")
  local expanded = M.render_preview({})
  truthy(index_of(expanded, '▾ "a": {') ~= nil, "expanded line missing")
end)

test("applies the initial fold level", function()
  local panel = render('{"a":{"b":{"c":1}},"d":2}', { fold_level = 2 })
  truthy(index_of(panel, '▾ "a": {') ~= nil, "level 2 should keep $.a expanded")
  truthy(index_of(panel, '  ▸ "b": { … 1 key }') ~= nil, "level 2 should collapse $.a.b")
  truthy(index_of(panel, '"d": 2') ~= nil, "scalar sibling missing")
  local level_one = render('{"a":{"b":1}}', { fold_level = 1 })
  truthy(index_of(level_one, '▸ "a": { … 1 key }') ~= nil, "level 1 should collapse $.a")
end)

test("folds all nested containers and expands them again", function()
  local text = '{"a":{"b":1},"c":[1,2],"e":{}}'
  render(text)
  current_doc = {
    path = "/tmp/test.json",
    text = text,
    line = 1,
    column = 1,
    selection_start = 0,
    selection_end = 0,
  }
  notifications = {}
  M.fold_all({})
  truthy(any_notification("folded 2 nodes"), "fold-all notification missing")
  local folded = M.render_preview({})
  check_panel(folded)
  truthy(index_of(folded, '▸ "a": { … 1 key }') ~= nil, "$.a should be folded")
  truthy(index_of(folded, '▸ "c": [ … 2 items ]') ~= nil, "$.c should be folded")
  truthy(index_of(folded, '"e": {}') ~= nil, "empty objects should not be folded")
  truthy(index_of(folded, "▾ {") ~= nil, "root should stay expanded")
  M.expand_all({})
  local expanded = M.render_preview({})
  truthy(index_of(expanded, "▸") == nil, "expand-all left a folded node")
end)

test("shows JSONPath notes when the setting is enabled", function()
  local panel = render('{"a":{"b":[1]}}', { show_paths = true })
  truthy(index_of(panel, "$.a") ~= nil, "$.a note missing")
  truthy(index_of(panel, "$.a.b[0]") ~= nil, "$.a.b[0] note missing")
end)

test("generates JSONPath segments for keys and arrays", function()
  local text = '{"a b":{"x":1},"arr":[{"k":2}]}'
  local node = assert(parse(text))
  local position = assert(text:find("2", 1, true))
  local found = I.locate_node(node, position)
  truthy(found, "cursor lookup failed")
  eq(found.path, "$.arr[0].k")
  eq(I.append_key_path("$", "a"), "$.a")
  eq(I.append_key_path("$", "a b"), '$["a b"]')
end)

test("evaluates JSONPath selectors and reports syntax errors", function()
  local root = assert(parse('{"users":[{"name":"Ada","age":36},{"name":"Bo","age":7}],"meta":{"name":"M"}}'))
  local function paths(expression)
    local segments = assert(I.parse_jsonpath(expression))
    local matches = I.evaluate_jsonpath(root, segments)
    local out = {}
    for _, match in ipairs(matches) do
      out[#out + 1] = match.path
    end
    return out
  end
  local names = paths("$.users[*].name")
  eq(#names, 2)
  eq(names[1], "$.users[0].name")
  eq(names[2], "$.users[1].name")
  eq(paths("$['users'][0]['name']")[1], "$.users[0].name")
  eq(paths("$.users[-1].name")[1], "$.users[1].name")
  eq(#paths("$..name"), 3, "recursive descent should find all names")
  eq(#paths("$..*"), 9, "recursive wildcard should find every descendant")
  eq(paths("$.users[::-1].name")[1], "$.users[1].name")
  eq(#paths("$.users[0:1].name"), 1, "slice should select one item")
  eq(#paths("$.users[0,1].name"), 2, "union should select both items")
  local ok, err = pcall(I.parse_jsonpath, "users[*]")
  truthy(not ok, "missing root should be rejected")
  contains(err.message, "must start with '$'")
  ok, err = pcall(I.parse_jsonpath, "$.users[?(@.age)]")
  truthy(not ok, "filters should be reported as unsupported")
  contains(err.message, "Expected a quoted key")
end)

test("renders JSONPath results in the inspector", function()
  current_doc = {
    path = "/tmp/jsonpath.json",
    text = '{"users":[{"name":"Ada"},{"name":"Bo"}]}',
    line = 1,
    column = 1,
    selection_start = 0,
    selection_end = 0,
  }
  current_settings = {}
  I.inspector_state.mode = "jsonpath"
  I.inspector_state.expression = "$.users[*].name"
  local panel = M.render_inspector({})
  check_panel(panel)
  contains(panel.lines[1].text, "JSONPath Results")
  truthy(index_of(panel, "Matches     2") ~= nil, "match count missing")
  truthy(index_of(panel, "Ada") ~= nil, "first match missing")
  truthy(index_of(panel, "Bo") ~= nil, "second match missing")
end)

test("reports JSON metadata including duplicate keys and depth", function()
  local text = '{\n  "a": [1, 2],\n  "b": "xy",\n  "a": 3,\n  "c": null,\n  "d": true,\n  "e": {}\n}'
  current_doc = {
    path = "/tmp/metadata.json",
    text = text,
    line = 1,
    column = 1,
    selection_start = 0,
    selection_end = 0,
  }
  current_settings = {}
  local analysis = assert(I.analysis_document("test"))
  local panel = I.render_metadata(analysis)
  check_panel(panel)
  eq(panel.title, "JSON Metadata")
  truthy(index_of(panel, "Objects") ~= nil, "type counts missing")
  truthy(index_of(panel, "Values") ~= nil, "values section missing")
  truthy(index_of(panel, "Duplicate keys") ~= nil, "duplicate section missing")
  truthy(index_of(panel, "Max depth") ~= nil, "depth missing")
  truthy(index_of(panel, "Top-level keys") ~= nil, "top-level keys missing")
  notifications = {}
  M.show_metadata({})
  eq(I.inspector_state.mode, "metadata")
  truthy(any_notification("open:json.inspector.panel"), "inspector was not opened")
end)

test("extracts JSONPath from the selection or the setting", function()
  local text = '{"query":"$.users[0].name","users":[{"name":"Ada"}]}'
  local expression = "$.users[0].name"
  local byte_start = assert(text:find(expression, 1, true))
  local start_char = utf8.len(text:sub(1, byte_start - 1))
  current_doc = {
    path = "/tmp/extract.json",
    text = text,
    line = 1,
    column = 1,
    selection_start = start_char,
    selection_end = start_char + #expression,
  }
  current_settings = {}
  notifications = {}
  M.extract_jsonpath({})
  eq(I.inspector_state.expression, expression)
  truthy(any_notification("open:json.inspector.panel"), "inspector was not opened")
  current_doc.selection_start = 0
  current_doc.selection_end = 0
  current_settings = { jsonpath = "$.users[*].name" }
  notifications = {}
  M.extract_jsonpath({})
  eq(I.inspector_state.expression, "$.users[*].name")
  current_settings = { jsonpath = "users" }
  notifications = {}
  M.extract_jsonpath({})
  truthy(any_notification("invalid JSONPath"), "invalid expression was not reported")
end)

test("shows the JSONPath of the value at the cursor", function()
  local text = '{"users":[{"name":"Ada"}]}'
  local starts = I.compute_line_starts(text)
  local position = assert(text:find("Ada", 1, true))
  local location = I.locate(text, starts, position)
  current_doc = {
    path = "/tmp/showpath.json",
    text = text,
    line = location.line,
    column = location.column,
    selection_start = 0,
    selection_end = 0,
  }
  current_settings = {}
  notifications = {}
  M.show_jsonpath({})
  eq(I.inspector_state.path, "$.users[0].name")
  truthy(any_notification("JSONPath: $.users[0].name"), "path notification missing")
  local panel = M.render_inspector({})
  check_panel(panel)
  eq(panel.title, "JSONPath at Cursor")
  contains(panel.lines[1].text, "Path")
  truthy(index_of(panel, "Ada") ~= nil, "value missing from the inspector")
end)

test("folds, analyzes and queries JSON Lines records", function()
  local text = '{"a":1}\n{"b":{"c":2}}\n'
  local panel = render(text)
  contains(panel.title, "JSON Lines · 2 records", "summary missing from title")
  current_doc = {
    path = "/tmp/test.json",
    text = text,
    line = 2,
    column = 7,
    selection_start = 0,
    selection_end = 0,
  }
  notifications = {}
  M.toggle_fold({})
  truthy(any_notification("folded $.b"), "JSON Lines fold notification missing")
  local folded = M.render_preview({})
  check_panel(folded)
  truthy(index_of(folded, '▸ "b": { … 1 key }') ~= nil, "JSON Lines fold missing")
  local analysis = assert(I.analysis_document("test"))
  local metadata = I.render_metadata(analysis)
  check_panel(metadata)
  truthy(index_of(metadata, "2 records") ~= nil, "record count missing")
  local results = I.render_jsonpath_results(analysis, "$.b.c")
  check_panel(results)
  truthy(index_of(results, "Line 2 · $.b.c = 2") ~= nil, "JSON Lines JSONPath result missing")
end)

io.write(string.format("\n%d passed, %d failed\n", PASSED, FAILED))
if FAILED > 0 then
  os.exit(1)
end
