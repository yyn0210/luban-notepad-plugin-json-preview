-- Fold state and tree rendering for the JSON Preview plugin.
--
-- Split out of the 1.x main.lua. The fold state is a plain in-memory table
-- keyed by exact fold paths (the 2 KiB path-hash cap and the suffix-hash
-- scheme are gone: paths are bounded by the parser's 256-level depth cap).
-- The state is written through to `state.json` in the plugin data directory
-- on every fold change, so folds survive a restart or a VM rebuild; the file
-- is loaded once at activate and a missing file simply means "no folds yet".
--
-- Panel lines carry `{ id, args }` commands (v2): every foldable container
-- line toggles itself via `json.fold.toggle` with its fold path as the arg,
-- so clicks no longer depend on reopening the panel.

local D = require("json.display")
local J = require("json.path")
local P = require("json.parser")

local M = {}

local MAX_SOURCE_BYTES = 512 * 1024
local MAX_RENDER_LINES = 4000
local MAX_ERROR_COLUMNS = 160
local MAX_FOLD_ENTRIES = 10000
local STATE_FILE = "state.json"
local STATE_VERSION = 1
local FOLD_COMMAND = "json.fold.toggle"

local normalize_text = D.normalize_text
local utf8_prefix = D.utf8_prefix
local plural = D.plural
local describe_node = D.describe_node

local compute_line_starts = P.compute_line_starts
local line_number_at = P.line_number_at
local locate = P.locate
local parse_json = P.parse

local child_paths = J.child_paths
local array_child_paths = J.array_child_paths
local walk_containers = J.walk_containers

-- ===========================================================================
-- Fold state (in memory, written through to the data directory)
-- ===========================================================================

local fold_state = {
  doc_key = nil,
  signature = nil,
  level = nil,
  collapsed = {},
  count = 0,
  seeded = false,
}

local function clear_collapsed()
  for path in pairs(fold_state.collapsed) do
    fold_state.collapsed[path] = nil
  end
  fold_state.count = 0
end

local function reset_state()
  clear_collapsed()
  fold_state.doc_key = nil
  fold_state.signature = nil
  fold_state.level = nil
  fold_state.seeded = false
end

-- Encode the state and write it to the data directory. Persistence must
-- never break folding: every failure is swallowed (with a log line).
local function persist_state()
  local api = type(luban) == "table" and luban or nil
  if not api
    or type(api.json) ~= "table" or type(api.json.encode) ~= "function"
    or type(api.fs) ~= "table" or type(api.fs.write) ~= "function"
  then
    return
  end
  local paths = {}
  for path in pairs(fold_state.collapsed) do
    paths[#paths + 1] = path
  end
  table.sort(paths)
  local ok, payload = pcall(api.json.encode, {
    version = STATE_VERSION,
    doc_key = fold_state.doc_key,
    signature = fold_state.signature,
    level = fold_state.level,
    seeded = fold_state.seeded,
    collapsed = paths,
  })
  if not ok or type(payload) ~= "string" then
    return
  end
  local ok_write, err = pcall(api.fs.write, STATE_FILE, payload)
  if not ok_write and type(api.log) == "function" then
    api.log("warn", "JSON Preview: cannot persist the fold state: " .. tostring(err))
  end
end

-- Load the persisted fold state. Called once at activate. A missing file,
-- unreadable file or corrupt payload is tolerated: the fold state starts
-- empty and the next render seeds it.
local function load_state()
  local api = type(luban) == "table" and luban or nil
  if not api
    or type(api.json) ~= "table" or type(api.json.decode) ~= "function"
    or type(api.fs) ~= "table" or type(api.fs.read) ~= "function"
  then
    return false
  end
  local ok_read, text = pcall(api.fs.read, STATE_FILE)
  if not ok_read or type(text) ~= "string" then
    return false
  end
  local ok_decode, data = pcall(api.json.decode, text)
  if not ok_decode or type(data) ~= "table" then
    return false
  end
  if type(data.doc_key) ~= "string" or type(data.collapsed) ~= "table" then
    return false
  end
  reset_state()
  local restored = 0
  for _, path in ipairs(data.collapsed) do
    if restored >= MAX_FOLD_ENTRIES then
      break
    end
    if type(path) == "string" and path ~= "" then
      fold_state.collapsed[path] = true
      restored = restored + 1
    end
  end
  fold_state.count = restored
  fold_state.doc_key = data.doc_key
  if type(data.signature) == "string" then
    fold_state.signature = data.signature
  end
  if type(data.level) == "number" then
    fold_state.level = math.floor(data.level)
  end
  fold_state.seeded = data.seeded == true
  return true
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
    persist_state()
  end
  if not fold_state.seeded then
    seed_fold_level(roots, fold_level)
    fold_state.seeded = true
    persist_state()
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

local function folded_count(roots, collapsed)
  collapsed = collapsed or fold_state.collapsed
  local total = 0
  for _, root in ipairs(roots or {}) do
    total = total + count_visible_folded(root.node, root.fold_prefix or "$", collapsed)
  end
  return total
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
  persist_state()
end

local function expand_all()
  clear_collapsed()
  fold_state.seeded = true
  persist_state()
end

-- Fold or unfold one node by its exact fold path (the value carried by the
-- per-node command args). Writes the state through.
local function fold_path_node(path)
  if not add_collapsed(path) then
    return false
  end
  persist_state()
  return true
end

local function unfold_path_node(path)
  if not fold_state.collapsed[path] then
    return true
  end
  remove_collapsed(path)
  persist_state()
  return true
end

-- on_edit payload: the edited document snapshot, or nil when a tab closed.
-- Same-document edits keep the folds; the root signature is re-derived and
-- compared on the next render, so stale paths for removed keys cannot linger.
-- A document switch or a tab close drops the state immediately.
local function note_edit(doc)
  if doc == nil then
    reset_state()
    persist_state()
    return
  end
  if fold_state.doc_key ~= nil and fold_state.doc_key ~= document_key(doc) then
    reset_state()
    persist_state()
  end
end

-- ===========================================================================
-- Tree rendering
-- ===========================================================================

local indent_caches = {}

local function indent_cache(indent)
  local cache = indent_caches[indent]
  if cache then
    return cache
  end
  cache = { [0] = "" }
  for depth = 1, P.MAX_DEPTH do
    cache[depth] = cache[depth - 1] .. string.rep(" ", indent)
  end
  indent_caches[indent] = cache
  return cache
end

local function finish_line(tokens, notes, line_style)
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
  if #text > D.MAX_LINE_BYTES then
    return { text = utf8_prefix(text, D.MAX_LINE_BYTES - 1) .. "…", style = line_style or "code" }
  end
  if #spans > 400 then
    spans = nil
  end
  return { text = text, style = line_style or "code", spans = spans }
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

-- The per-node fold command: every foldable container line toggles itself
-- through its exact fold path, so a click never depends on the cursor.
local function fold_command(fold_path)
  return { id = FOLD_COMMAND, args = { path = fold_path } }
end

local function build_panel_actions(folded)
  local toggle = folded > 0 and "Expand All" or "Fold All"
  local toggle_zh = folded > 0 and "全部展开" or "全部折叠"
  return {
    {
      label = toggle,
      label_i18n = { ["zh-CN"] = toggle_zh },
      command = { id = "json.fold.toggle-all" },
    },
    { label = "JSONPath", command = { id = "json.path.action" } },
    {
      label = "Metadata",
      label_i18n = { ["zh-CN"] = "元数据" },
      command = { id = "json.metadata" },
    },
  }
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
  local object_pairs = nil
  local array_count = 0
  if node.type == "object" then
    object_pairs = D.ordered_pairs(node, opts.sort_keys)
  elseif node.type == "array" then
    array_count = #node.items
  end
  local container_count = object_pairs and #object_pairs or array_count
  local collapsed = container_count > 0
    and opts.collapsed
    and opts.collapsed[fold_path]
  local tokens = {}
  if container_count > 0 then
    -- Keep the triangle in the indent gutter so keys stay aligned with scalar
    -- siblings, matching common JSON tree viewers.
    local gutter = indents[math.max(0, depth - 1)]
    tokens[#tokens + 1] = { text = gutter }
    tokens[#tokens + 1] = { text = collapsed and "▸ " or "▾ ", style = "muted" }
    local padding = #indents[depth] - #gutter - 2
    if padding > 0 then
      tokens[#tokens + 1] = { text = string.rep(" ", padding) }
    end
  else
    tokens[#tokens + 1] = { text = indents[depth] }
  end
  for _, token in ipairs(prefix) do
    tokens[#tokens + 1] = token
  end
  if node.type == "object" then
    local pairs = object_pairs
    if #pairs == 0 then
      tokens[#tokens + 1] = { text = "{}", role = "punctuation.bracket" }
      if suffix ~= "" then
        tokens[#tokens + 1] = { text = suffix, role = "punctuation" }
      end
      return push_line(renderer, finish_line(tokens, combine_notes(notes, opts, display_path), opts.line_style))
    end
    if collapsed then
      tokens[#tokens + 1] = { text = "{", role = "punctuation.bracket" }
      tokens[#tokens + 1] = {
        text = string.format(" … %d %s ", #pairs, plural(#pairs, "key", "keys")),
        style = "muted",
      }
      tokens[#tokens + 1] = { text = "}", role = "punctuation.bracket" }
      if suffix ~= "" then
        tokens[#tokens + 1] = { text = suffix, role = "punctuation" }
      end
      local line = finish_line(tokens, combine_notes(notes, opts, display_path), opts.line_style)
      line.command = fold_command(fold_path)
      return push_line(renderer, line)
    end
    tokens[#tokens + 1] = { text = "{", role = "punctuation.bracket" }
    local open_line = finish_line(tokens, combine_notes(notes, opts, display_path), opts.line_style)
    open_line.command = fold_command(fold_path)
    if not push_line(renderer, open_line) then
      return false
    end
    for index, pair in ipairs(pairs) do
      local key_text = D.display_string(pair.key, D.MAX_KEY_DISPLAY)
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
    local close_indent = depth == 0 and string.rep(" ", opts.indent) or indents[depth]
    local close_tokens = {
      { text = close_indent },
      { text = "}", role = "punctuation.bracket" },
    }
    if suffix ~= "" then
      close_tokens[#close_tokens + 1] = { text = suffix, role = "punctuation" }
    end
    return push_line(renderer, finish_line(close_tokens, nil, opts.line_style))
  elseif node.type == "array" then
    if array_count == 0 then
      tokens[#tokens + 1] = { text = "[]", role = "punctuation.bracket" }
      if suffix ~= "" then
        tokens[#tokens + 1] = { text = suffix, role = "punctuation" }
      end
      return push_line(renderer, finish_line(tokens, combine_notes(notes, opts, display_path), opts.line_style))
    end
    if collapsed then
      tokens[#tokens + 1] = { text = "[", role = "punctuation.bracket" }
      tokens[#tokens + 1] = {
        text = string.format(" … %d %s ", array_count, plural(array_count, "item", "items")),
        style = "muted",
      }
      tokens[#tokens + 1] = { text = "]", role = "punctuation.bracket" }
      if suffix ~= "" then
        tokens[#tokens + 1] = { text = suffix, role = "punctuation" }
      end
      local line = finish_line(tokens, combine_notes(notes, opts, display_path), opts.line_style)
      line.command = fold_command(fold_path)
      return push_line(renderer, line)
    end
    tokens[#tokens + 1] = { text = "[", role = "punctuation.bracket" }
    local open_line = finish_line(tokens, combine_notes(notes, opts, display_path), opts.line_style)
    open_line.command = fold_command(fold_path)
    if not push_line(renderer, open_line) then
      return false
    end
    for index, item in ipairs(node.items) do
      local child_suffix = index < #node.items and "," or ""
      local child_display, child_fold = array_child_paths(display_path, fold_path, index - 1)
      if not render_value(renderer, item, depth + 1, {}, child_suffix, nil, opts, line_for_pos, child_display, child_fold) then
        return false
      end
    end
    local close_indent = depth == 0 and string.rep(" ", opts.indent) or indents[depth]
    local close_tokens = {
      { text = close_indent },
      { text = "]", role = "punctuation.bracket" },
    }
    if suffix ~= "" then
      close_tokens[#close_tokens + 1] = { text = suffix, role = "punctuation" }
    end
    return push_line(renderer, finish_line(close_tokens, nil, opts.line_style))
  end
  local value_notes = {}
  if notes then
    for _, note in ipairs(notes) do
      value_notes[#value_notes + 1] = note
    end
  end
  if node.type == "string" then
    local text, truncated, total = D.display_string(node.value, D.MAX_STRING_DISPLAY)
    tokens[#tokens + 1] = { text = text, role = "string" }
    if truncated then
      value_notes[#value_notes + 1] = string.format("%d chars total", total)
    end
  elseif node.type == "number" then
    local raw, truncated = D.display_number(node.raw)
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
  return push_line(renderer, finish_line(tokens, combine_notes(value_notes, opts, display_path), opts.line_style))
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
  push_line(renderer, { text = "", style = "rule" })
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
  push_line(renderer, { text = "", style = "rule" })
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
    local content = D.sanitize_excerpt(text:sub(line_start, line_end))
    local caret = nil
    if line == loc.line then
      local prefix = D.sanitize_excerpt(text:sub(line_start, math.min(err.pos - 1, line_end)))
      caret = D.display_width(prefix)
      local content_width = D.display_width(content)
      if content_width > MAX_ERROR_COLUMNS then
        local window = math.max(0, caret - math.floor(MAX_ERROR_COLUMNS / 2))
        if window + MAX_ERROR_COLUMNS > content_width then
          window = math.max(0, content_width - MAX_ERROR_COLUMNS)
        end
        local sliced, skipped = D.display_slice(content, window, MAX_ERROR_COLUMNS)
        local leading = skipped > 0 and "…" or ""
        local trailing = (window + MAX_ERROR_COLUMNS < content_width) and "…" or ""
        content = leading .. sliced .. trailing
        caret = caret - skipped + (leading ~= "" and 1 or 0)
        if caret < 0 then
          caret = 0
        end
      end
    elseif D.display_width(content) > MAX_ERROR_COLUMNS then
      content = D.display_slice(content, 0, MAX_ERROR_COLUMNS - 1) .. "…"
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

local function document_title(doc, description)
  local path = doc.path
  local name = nil
  if type(path) == "string" and path ~= "" then
    name = path:match("([^/\\]+)$") or path
  end
  local preview = "JSON Preview"
  if luban.i18n and luban.i18n.pick then
    preview = luban.i18n.pick({ en = "JSON Preview", ["zh-CN"] = "JSON 预览" })
  end
  if name then
    if description then
      return name .. " — " .. description
    end
    return name .. " — " .. preview
  end
  if description then
    return description
  end
  return preview
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
    return {
      title = document_title(doc, describe_node(root)),
      lines = lines,
      actions = build_panel_actions(folded_count(roots, opts.collapsed)),
    }
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
      return {
        title = document_title(doc, string.format("JSON Lines · %d records", #records)),
        lines = render_json_lines(text, records, opts, roots),
        actions = build_panel_actions(folded_count(roots, opts.collapsed)),
      }
    end
  end
  return { title = document_title(doc), lines = render_error(text, root, truncated) }
end

-- ===========================================================================
-- Exports
-- ===========================================================================

M.MAX_SOURCE_BYTES = MAX_SOURCE_BYTES
M.MAX_FOLD_ENTRIES = MAX_FOLD_ENTRIES
M.fold_state = fold_state
M.indent_cache = indent_cache
M.ensure_fold_state = ensure_fold_state
M.folded_count = folded_count
M.fold = fold_path_node
M.unfold = unfold_path_node
M.fold_all = fold_all
M.expand_all = expand_all
M.note_edit = note_edit
M.load_state = load_state
M.reset = reset_state
M.render_document = render_document
M.render_error = render_error
M.parse_json_lines = parse_json_lines

return M
