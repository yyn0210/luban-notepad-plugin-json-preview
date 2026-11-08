-- Metadata statistics for the JSON Preview plugin (the JSON: Metadata entry).
--
-- Split out of the 1.x main.lua; the statistic bodies and the rendered panel
-- layout are unchanged. Exported as `statistics(analysis)`.

local D = require("json.display")
local J = require("json.path")
local P = require("json.parser")

local M = {}

local format_bytes = D.format_bytes
local plural = D.plural
local char_count = D.char_count
local encode_string = D.encode_string
local clip_text = D.clip_text
local append_key_path = J.append_key_path
local append_index_path = J.append_index_path
local compute_line_starts = P.compute_line_starts
local line_number_at = P.line_number_at

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
  lines[#lines + 1] = { text = clip_text(text, D.MAX_LINE_BYTES - 1), style = style or "text" }
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

local function source_label(doc)
  local path = doc.path
  if type(path) == "string" and path ~= "" then
    return path:match("([^/\\]+)$") or path
  end
  return "Untitled"
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

M.statistics = render_metadata
M.metadata_line = metadata_line
M.new_stats = new_stats
M.collect_stats = collect_stats

return M
