-- JSON Preview for Luban Notepad (plugin API v2).
--
-- Assembly only: the machinery lives in the json/ modules, loaded through the
-- sandboxed in-plugin require (json.parser -> json/parser.lua):
--
--   json/parser.lua  strict RFC 8259 parser + source locations
--   json/display.lua width, formatting and string-display helpers
--   json/path.lua    JSONPath, path building and document positions
--   json/tree.lua    fold state (in memory + state.json) and tree rendering
--   json/meta.lua    metadata statistics
--
-- This file wires the manifest-declared entries, the inspector and the fold
-- commands. Requires a host with luban.version == 2. The preview reads the
-- active document through luban.document.get(); the fold state is written
-- through to state.json in the plugin data directory, which is why the
-- manifest declares the filesystem permission.

local D = require("json.display")
local P = require("json.parser")
local J = require("json.path")
local T = require("json.tree")
local MT = require("json.meta")

local M = {}

local PANEL_ID = "json.preview.panel"
local INSPECTOR_ID = "json.inspector.panel"
local MAX_COMMAND_BYTES = 512 * 1024
local MAX_JSONPATH_MATCHES = J.MAX_JSONPATH_MATCHES
local MAX_JSONPATH_DISPLAY = J.MAX_JSONPATH_DISPLAY

local normalize_text = D.normalize_text
local utf8_prefix = D.utf8_prefix
local trim = D.trim
local clip_text = D.clip_text
local plural = D.plural
local format_bytes = D.format_bytes
local describe_node = D.describe_node
local count_duplicates = D.count_duplicates
local encode_string = D.encode_string
local display_string = D.display_string
local display_number = D.display_number

local parse_json = P.parse
local compute_line_starts = P.compute_line_starts
local locate = P.locate

-- Older hosts do not expose luban.i18n; they keep the English titles.
local function pick(english, chinese)
  if luban.i18n and luban.i18n.pick then
    return luban.i18n.pick({ en = english, ["zh-CN"] = chinese })
  end
  return english
end

local function preview_title()
  return pick("JSON Preview", "JSON 预览")
end

local function inspector_title()
  return pick("JSON Inspector", "JSON 检查器")
end

local char_offset_at = J.char_offset_at
local byte_offset_at = J.byte_offset_at
local sub_chars = J.sub_chars
local locate_node = J.locate_node
local parse_jsonpath = J.parse_jsonpath
local evaluate_jsonpath = J.evaluate_jsonpath

-- ===========================================================================
-- Plain serialization (format and minify commands)
-- ===========================================================================

local function serialize(node, opts, depth, buffer)
  if node.type == "object" then
    local pairs = D.ordered_pairs(node, opts.sort_keys)
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
-- Settings, documents and commands
-- ===========================================================================

local function setting_bool(key, default)
  local value = luban.settings.get(key)
  if type(value) == "boolean" then
    return value
  end
  return default
end

local function setting_int(key, default, minimum, maximum)
  local value = luban.settings.get(key)
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
  local value = luban.settings.get(key)
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
    collapsed = T.fold_state.collapsed,
    line_style = "table",
    indents = T.indent_cache(indent),
  }
end

local function notify(message)
  luban.notify(message)
end

local function active_document()
  local doc = luban.document.get()
  if type(doc) == "table" and type(doc.text) == "string" then
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

-- document.set_text is a v2 mutator: it returns nothing and raises when the
-- document cannot be replaced, so a failure is reported as a notification.
local function update_document(command, output)
  local ok, err = pcall(luban.document.set_text, output, 0, 0)
  if not ok then
    notify(command .. ": " .. tostring(err))
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
  if #text > T.MAX_SOURCE_BYTES then
    text = utf8_prefix(text, T.MAX_SOURCE_BYTES)
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
    local records = T.parse_json_lines(text)
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

-- ===========================================================================
-- Inspector rendering (JSONPath results and paths at the cursor)
-- ===========================================================================

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
  MT.metadata_line(lines, message, "text")
  MT.metadata_line(lines, "Expression: " .. clip_text(expression, 300), "muted")
  local shown = clip_text(expression, 300)
  local caret = math.max(0, math.min(pos - 1, #shown))
  MT.metadata_line(lines, string.rep(" ", caret) .. "^", "code")
  return { title = pick("JSONPath", "JSONPath"), lines = lines }
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
  MT.metadata_line(lines, "Expression  " .. clip_text(expression, 300), "code")
  local match_text = tostring(total)
  if truncated then
    match_text = match_text .. " (capped)"
  elseif display_capped then
    match_text = match_text .. "+ (first " .. MAX_JSONPATH_DISPLAY .. " shown)"
  end
  MT.metadata_line(lines, "Matches     " .. match_text, "muted")
  if total == 0 then
    MT.metadata_line(lines, "No values match this expression.", "muted")
    return { title = pick("JSONPath", "JSONPath"), lines = lines }
  end
  local shown = math.min(#results, MAX_JSONPATH_DISPLAY)
  for index = 1, shown do
    local match = results[index]
    local prefix = match.line and string.format("Line %d · ", match.line) or ""
    local path = prefix .. match.path
    if match.duplicate then
      path = path .. string.format(" (duplicate #%d)", match.duplicate)
    end
    MT.metadata_line(
      lines,
      string.format("%d  %s = %s", index, clip_text(path, 220), value_preview(match.node, 160)),
      "code"
    )
  end
  if total > shown then
    MT.metadata_line(lines, string.format("Showing the first %d of %d matches.", shown, total), "muted")
  end
  if truncated then
    MT.metadata_line(lines, string.format("Evaluation stopped after %d matches.", MAX_JSONPATH_MATCHES), "muted")
  end
  return { title = pick("JSONPath", "JSONPath"), lines = lines }
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
      MT.metadata_line(lines, "The cursor is not on a JSON Lines record.", "muted")
      return { title = pick("JSONPath at Cursor", "光标处的 JSONPath"), lines = lines }
    end
  end
  local prefix = (analysis.kind == "jsonl" and line) and string.format("Line %d · ", line) or ""
  MT.metadata_line(lines, "Path   " .. prefix .. clip_text(path, 300), "code")
  if not type_text then
    local match, err = find_jsonpath_match(root, path)
    if not match then
      local message = type(err) == "table" and err.message or "The path no longer resolves."
      MT.metadata_line(lines, message, "muted")
      return { title = pick("JSONPath at Cursor", "光标处的 JSONPath"), lines = lines }
    end
    type_text = describe_node(match.node)
    value_text = value_preview(match.node, 240)
  end
  MT.metadata_line(lines, "Type   " .. type_text, "muted")
  MT.metadata_line(lines, "Value  " .. value_text, "code")
  return { title = pick("JSONPath at Cursor", "光标处的 JSONPath"), lines = lines }
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
  luban.panel.open(INSPECTOR_ID)
end

function M.render_inspector(ctx)
  local function build()
    local analysis = analysis_document("JSON Inspector")
    if not analysis then
      local doc = active_document()
      if doc then
        local text = normalize_text(type(doc.text) == "string" and doc.text or "")
        local truncated = false
        if #text > T.MAX_SOURCE_BYTES then
          text = utf8_prefix(text, T.MAX_SOURCE_BYTES)
          truncated = true
        end
        local ok, root = pcall(parse_json, text)
        if not ok and type(root) == "table" and root.json_error then
          return { title = inspector_title(), lines = T.render_error(text, root, truncated) }
        end
      end
      return {
        title = inspector_title(),
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
    return MT.statistics(analysis)
  end
  local ok, result = pcall(build)
  if not ok then
    luban.log("error", "json inspector failed: " .. tostring(result))
    return {
      title = inspector_title(),
      lines = { { text = "Inspector failed: " .. tostring(result), style = "muted" } },
    }
  end
  return result
end

-- ===========================================================================
-- Manifest-declared entries
-- ===========================================================================

function M.open_preview(ctx)
  luban.panel.open(PANEL_ID)
end

function M.render_preview(ctx)
  local doc = active_document()
  if not doc then
    return {
      title = preview_title(),
      lines = { { text = "Preview is not available for this document.", style = "muted" } },
    }
  end
  local opts = preview_options()
  local ok, result = pcall(T.render_document, doc, opts)
  if not ok then
    luban.log("error", "json preview failed: " .. tostring(result))
    return {
      title = preview_title(),
      lines = { { text = "Preview failed: " .. tostring(result), style = "muted" } },
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

-- args = { path = ... } toggles the foldable container whose panel line was
-- clicked (the exact fold path the line carries). Without args — the keyboard
-- path — the deepest container at the cursor is toggled instead. Either way
-- the preview panel is refreshed in place: the host keeps the scroll position
-- and only re-renders when the panel is open.
function M.toggle_fold(ctx, args)
  local analysis = analysis_document("JSON: cannot fold")
  if not analysis then
    return
  end
  T.ensure_fold_state(analysis.doc, analysis.roots, preview_options().fold_level)
  local path = nil
  local display = nil
  if type(args) == "table" and type(args.path) == "string" and args.path ~= "" then
    path = args.path
  else
    local starts = compute_line_starts(analysis.text)
    local line = doc_line(analysis.doc)
    local char_index = char_offset_at(analysis.text, line, doc_column(analysis.doc))
    local byte = byte_offset_at(analysis.text, char_index)
    local found = nil
    if analysis.kind == "json" then
      found = locate_node(analysis.root, byte, "$", "$")
    else
      for _, record in ipairs(analysis.records) do
        if record.source_line == line then
          found = locate_node(record.root, byte - starts[line] + 1, "$", "L" .. line .. "$")
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
    path = container.fold_path
    display = container.path
  end
  if T.fold_state.collapsed[path] then
    T.unfold(path)
    notify("JSON: expanded " .. clip_text(display or path, 120))
  else
    if not T.fold(path) then
      notify("JSON: too many folded nodes.")
      return
    end
    notify("JSON: folded " .. clip_text(display or path, 120))
  end
  luban.panel.refresh(PANEL_ID)
end

function M.fold_all(ctx)
  local analysis = analysis_document("JSON: cannot fold")
  if not analysis then
    return
  end
  T.ensure_fold_state(analysis.doc, analysis.roots, preview_options().fold_level)
  T.fold_all(analysis.roots)
  luban.panel.refresh(PANEL_ID)
  notify(string.format("JSON: folded %d nodes.", T.fold_state.count))
end

function M.expand_all(ctx)
  local analysis = analysis_document("JSON: cannot expand")
  if not analysis then
    return
  end
  T.ensure_fold_state(analysis.doc, analysis.roots, preview_options().fold_level)
  T.expand_all()
  luban.panel.refresh(PANEL_ID)
  notify("JSON: expanded all nodes.")
end

function M.toggle_all_folds(ctx)
  local analysis = analysis_document("JSON: cannot fold")
  if not analysis then
    return
  end
  T.ensure_fold_state(analysis.doc, analysis.roots, preview_options().fold_level)
  local folded = T.folded_count(analysis.roots)
  if folded > 0 then
    T.expand_all()
    luban.panel.refresh(PANEL_ID)
    notify("JSON: expanded all nodes.")
  else
    T.fold_all(analysis.roots)
    luban.panel.refresh(PANEL_ID)
    if T.fold_state.count > 0 then
      notify(string.format("JSON: folded %d nodes.", T.fold_state.count))
    else
      notify("JSON: there are no nested objects or arrays to fold.")
    end
  end
end

function M.jsonpath_action(ctx)
  local doc = active_document()
  local has_selection = false
  if doc
    and type(doc.text) == "string"
    and type(doc.selection_start) == "number"
    and type(doc.selection_end) == "number"
    and doc.selection_end > doc.selection_start
  then
    has_selection = trim(sub_chars(doc.text, doc.selection_start, doc.selection_end)) ~= ""
  end
  if has_selection then
    M.extract_jsonpath(ctx)
  else
    M.show_jsonpath(ctx)
  end
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

-- ===========================================================================
-- Events and activation
-- ===========================================================================

-- on_edit payload: the document snapshot after the edit, or nil when a tab
-- closed. Invalidation only — the host re-renders `refresh: edit` panels
-- itself, and the fold state re-validates its root signature on the next
-- render, so stale fold paths cannot linger after a structural edit.
function M.on_edit(doc)
  T.note_edit(doc)
end

function M.activate(ctx)
  if type(luban) ~= "table" or (luban.version or 0) < 2 then
    error("JSON Preview requires plugin API v2 (luban.version >= 2); got "
      .. tostring(luban and luban.version or "no luban")
      .. ". Update Luban Notepad to a v2 host.")
  end
  luban.events.on("on_edit", M.on_edit)
  -- Restart/rebuild fallback for the fold state; a missing state.json simply
  -- means "nothing folded yet".
  T.load_state()
  luban.log("info", "JSON Preview activated")
end

-- Kept for the test harness and introspection; not part of the manifest.
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
  append_key_path = J.append_key_path,
  locate_node = locate_node,
  char_offset_at = char_offset_at,
  byte_offset_at = byte_offset_at,
  sub_chars = sub_chars,
  ensure_fold_state = T.ensure_fold_state,
  fold_state = T.fold_state,
  parse_jsonpath = parse_jsonpath,
  evaluate_jsonpath = evaluate_jsonpath,
  new_stats = MT.new_stats,
  collect_stats = MT.collect_stats,
  render_metadata = MT.statistics,
  render_jsonpath_results = render_jsonpath_results,
  render_path_at = render_path_at,
  analysis_document = analysis_document,
  inspector_state = inspector_state,
}

M._modules = {
  display = D,
  parser = P,
  path = J,
  tree = T,
  meta = MT,
}

return M
