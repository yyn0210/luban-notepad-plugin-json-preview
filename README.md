# JSON Preview for Luban Notepad

在 Luban Notepad 的右侧面板中预览当前 JSON 文档，并支持节点折叠、JSONPath
提取与 JSON 元数据分析。插件是单文件 Lua，运行在编辑器沙箱内，只读取当前
文档，不需要文件系统、网络或子进程权限。

A tree-style JSON preview for [Luban Notepad](https://github.com/yyn0210/luban-notepad)
with node folding, JSONPath extraction and metadata analysis. The plugin is a
single sandboxed Lua file and requests no permissions.

## 功能

- 严格 RFC 8259 解析：对象、数组、字符串（含 `\uXXXX` 和代理对）、数字、
  `true`/`false`/`null`；保留原始键顺序和重复键。
- 树状缩进预览，键、字符串、数字、布尔值、`null` 和标点使用当前语法主题配色。
- 节点折叠：对象/数组带 `▾`/`▸` 标记；可折叠光标所在节点、全部折叠、全部展开，
  也可以设置打开时自动折叠的层级。
- JSONPath：显示任意值的路径（`$.users[0].name`），支持按选区或设置中的表达式
  提取匹配值，并在 Inspector 面板列出路径与结果。
- JSON 元数据：值类型统计、最大深度、键数量、重复键、空容器、最大对象/数组、
  字符串总长度/最长字符串、数字整数/小数/指数分布与范围。
- 错误定位：显示原因、行号/列号、上下文源码和插入符；常见错误有专门提示
  （尾随逗号、注释、单引号、前导零、未配对代理项等）。
- 重复键提示：保留全部重复键，并在预览中标注首次出现的位置。
- 自动识别 JSON Lines：整篇不是单个 JSON 值、但每个非空行都是合法 JSON 时，
  按记录逐条预览并标注源行号。
- 编辑时自动刷新（约 150ms 防抖）；也可以点面板上的“刷新”。
- 命令：预览、折叠、JSONPath、元数据、格式化、压缩、校验。
- 旧版宿主自动降级：忽略富文本字段，显示纯文本回退和手动刷新。

## 兼容性

| 宿主版本 | 体验 |
| --- | --- |
| Luban Notepad 1.0.0-preview.2 及以后 | 着色预览、自动刷新、可调面板宽度、Inspector |
| Luban Notepad 1.0.0-preview.1 | 纯文本预览、手动刷新（插件仍可安装） |

插件清单的 `api_version` 为 1。

## 安装

- **插件商店**：插件 → 插件商店…，搜索 “JSON Preview”。
- **手动安装**：把本仓库的 `plugin.json` 和 `main.lua` 放进
  `<config-dir>/plugins/io.github.yyn0210.json-preview/`，然后在插件管理器中
  批准并启用（插件不申请任何权限）。

## 使用

| 命令 | 说明 | 快捷键 |
| --- | --- | --- |
| `JSON: Preview` | 打开或刷新右侧预览面板 | `Ctrl+Shift+J` |
| `JSON: Toggle Fold` | 折叠/展开光标所在的对象或数组 | `Ctrl+Alt+J` |
| `JSON: Fold All` | 折叠根节点以下的所有对象和数组 | — |
| `JSON: Expand All` | 展开所有已折叠节点 | — |
| `JSON: Show JSONPath` | 在 Inspector 中显示光标处值的 JSONPath | — |
| `JSON: Extract JSONPath` | 按选区（无选区时用设置）中的表达式提取匹配值 | — |
| `JSON: Metadata` | 在 Inspector 中显示 JSON 元数据 | — |
| `JSON: Format Document` | 按设置中的缩进宽度格式化当前文档 | — |
| `JSON: Minify Document` | 压缩为单行 JSON | — |
| `JSON: Validate` | 校验并报告类型、键/元素数量或错误位置 | — |

命令可从命令面板或“插件”菜单执行；快捷键可在快捷键编辑器中修改。

### 节点折叠

- 预览中的对象和数组用 `▾` 表示展开、`▸` 表示折叠；折叠行会显示隐藏的键或
  元素数量，例如 `"user": ▸ { … 3 keys }`。
- 宿主的面板行点击会先关闭面板再执行命令，无法在不丢失滚动位置的情况下用鼠标
  切换单个节点，因此折叠使用编辑器光标定位：把光标放在某个对象/数组内部，
  执行 `JSON: Toggle Fold`（默认 `Ctrl+Alt+J`）。
- `JSON: Fold All` 保留根节点展开，折叠根以下的所有容器；
  `JSON: Expand All` 清空所有折叠状态。
- 设置 `fold_level` 可以指定打开文档时的初始折叠层级：`0` 全部展开，
  `1` 只展开根，`2` 再展开根的直接子容器，依此类推。
- 折叠状态在当前文档的编辑过程中保留；根节点结构变化或切换文档时重置。
  自动刷新和重新打开面板都不会丢失折叠状态。

### JSONPath

- `JSON: Show JSONPath` 取光标所在的最内层值，在 Inspector 中显示路径、类型和
  值，同时把路径发到状态栏。
- `JSON: Extract JSONPath` 优先使用编辑器选区中的文本作为表达式；没有选区时
  使用插件设置 `jsonpath`。结果在 Inspector 中按 `路径 = 值` 列出；JSON Lines
  会标注记录所在行。
- 支持的语法子集：
  - 根：`$`
  - 子属性：`.name`、`['name']`、`["name"]`
  - 数组下标：`[0]`、`[-1]`
  - 通配符：`.*`、`[*]`
  - 递归下降：`..name`、`..*`、`..['name']`
  - 切片：`[start:end]`、`[start:end:step]`
  - 联合：`[0,2]`、`['a','b']`
- 不支持过滤表达式（如 `[?(@.age > 18)]`），会给出明确的语法错误提示。
- 设置 `show_paths` 可以把每个值的 JSONPath 以浅色注释附加到预览行尾。

### 元数据

`JSON: Metadata` 在 Inspector 中显示：值类型计数、最大深度及其路径、键总数与
重复键、空容器、最大对象/数组、字符串字符数与最长字符串、数字的整数/小数/
指数分布及数值范围、顶层键，以及 JSON Lines 的记录数。重复键最多列出 20 处，
其余显示剩余数量。

### Inspector 面板

Inspector 是一个独立的右侧面板，用于显示元数据、JSONPath 查询结果或光标处
路径。宿主同一时间只显示一个插件面板，打开 Inspector 会替换当前的预览面板；
再次执行 `JSON: Preview` 即可切回预览。

- 格式化保留原始键顺序和重复键，不会自动排序；排序只影响预览。
- 格式化/压缩通过 `luban.set_document_text` 修改文档，可撤销并走正常保存流程；
  完成后光标回到文档开头。
- 面板标题显示当前文件名；切换标签或编辑后自动跟随。

旧版宿主没有 `luban.panel.open`：预览命令会提示从“插件”菜单打开
“JSON Preview”面板。

## 设置

| 键 | 类型 | 默认 | 说明 |
| --- | --- | --- | --- |
| `indent` | number | `2` | 预览和格式化时每级缩进的空格数（1–8） |
| `sort_keys` | boolean | `false` | 仅在预览中按字母顺序排列对象键 |
| `json_lines` | boolean | `true` | 整篇不是单个 JSON 值时，尝试按 JSON Lines 预览 |
| `fold_level` | number | `0` | 初始折叠层级：0 全部展开，1 只展开根，2 再展开直接子容器…（0–16） |
| `show_paths` | boolean | `false` | 在预览行尾显示每个值的 JSONPath |
| `jsonpath` | string | 空 | 没有选区时供 `JSON: Extract JSONPath` 使用的表达式 |

## 限制

- 预览最多读取 512 KiB 源文本、渲染 4,000 行；超出会截断并提示。
- 单个字符串值在预览中最多显示 200 显示列，超出会以 `…` 截断并标注总字符数；
  格式化与压缩始终保留完整内容。
- 嵌套深度上限为 256 层。
- 折叠状态最多记录 10,000 个节点；超出时需要先展开再折叠。
- 极深的节点路径在显示时会截断并附带后缀哈希，避免超长路径拖慢预览。
- 严格 JSON：不接受注释、单引号字符串、尾随逗号和 `NaN`/`Infinity`。
- 预览是只读侧栏；格式化/压缩会重写整个文档，不保留原始空白和转义写法。
- 不支持 JSONC/JSON5 的注释与扩展语法。

## 开发

```bash
lua5.4 tests/run.lua            # 解析、渲染、折叠、JSONPath、元数据与命令测试
python3 scripts/package.py --check
python3 scripts/package.py      # 生成 dist/<id>-<version>.zip
```

发布流程：更新 `plugin.json` 与 `CHANGELOG.md` 的版本，提交并推送 `v<version>`
标签；`.github/workflows/release.yml` 会运行测试、打包并上传 GitHub Release。
商店目录的 `plugins/<id>.json` 需要记录该产物的 SHA-256 与字节数。

## 许可证

木兰公共许可证第 2 版（MulanPubL-2.0），见 [LICENSE](LICENSE)。
