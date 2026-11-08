# JSON Preview for Luban Notepad

在 Luban Notepad 的右侧面板中预览当前 JSON 文档，并支持节点折叠、JSONPath
提取与 JSON 元数据分析。插件面向插件 API v2（`luban.version >= 2`），Lua 代码
按模块拆分在 `json/` 目录下，通过宿主的沙箱内 `require` 加载。只读取当前文档；
为把折叠状态持久化到数据目录，申请了 `filesystem` 权限（不访问网络和子进程）。

A tree-style JSON preview for [Luban Notepad](https://github.com/yyn0210/luban-notepad)
with node folding, JSONPath extraction and metadata analysis. The plugin targets
plugin API v2 (`luban.version >= 2`) and is split into modules under `json/`,
loaded through the host's sandboxed in-plugin `require`. It only reads the
active document; the `filesystem` permission is requested solely to persist the
fold state in the plugin data directory.

## 功能

- 严格 RFC 8259 解析：对象、数组、字符串（含 `\uXXXX` 和代理对）、数字、
  `true`/`false`/`null`；保留原始键顺序和重复键。
- 树状缩进预览，键、字符串、数字、布尔值、`null` 和标点使用当前语法主题配色；
  树形行无灰色底块，折叠三角位于缩进槽中，键与同级标量对齐。
- 逐节点折叠：每个可折叠的对象/数组行自带 `{ id, args }` 点击命令，直接切换
  该节点的折叠状态；光标快捷键（`Ctrl+Alt+J`）仍然可用。
- 面板标题栏右侧提供 `Fold All`/`Expand All`、`JSONPath`、`Metadata` 三个
  扁平操作按钮；折叠、JSONPath、元数据入口不再占用正文行。
- JSONPath：显示任意值的路径（`$.users[0].name`），支持按选区或设置中的表达式
  提取匹配值，并在 Inspector 面板列出路径与结果。
- JSON 元数据：值类型统计、最大深度、键数量、重复键、空容器、最大对象/数组、
  字符串总长度/最长字符串、数字整数/小数/指数分布与范围。
- 错误定位：显示原因、行号/列号、上下文源码和插入符；常见错误有专门提示
  （尾随逗号、注释、单引号、前导零、未配对代理项等）。
- 重复键提示：保留全部重复键，并在预览中标注首次出现的位置。
- 自动识别 JSON Lines：整篇不是单个 JSON 值、但每个非空行都是合法 JSON 时，
  按记录逐条预览并标注源行号。
- `on_edit` 时失效折叠状态：同一文档的普通编辑保留折叠，根结构变化或切换文档
  时重置；宿主随后自动重绘 `refresh: edit` 面板。
- 折叠状态写入插件数据目录的 `state.json`：重启或插件 VM 重建后恢复上次的
  折叠（仅当文档路径与根结构未变时生效）。
- 命令：预览、折叠、JSONPath、元数据、格式化、压缩、校验。

## 兼容性

需要 `api_version: 2` 的宿主（`luban.version == 2`）。宿主会在激活时校验清单，
v1 宿主无法安装本插件；插件激活时也要求 `luban.version >= 2`，否则报错退出，
不再包含任何针对旧宿主的降级代码。

## 安装

- **插件商店**：插件 → 插件商店…，搜索 “JSON Preview”。
- **手动安装**：把本仓库的 `plugin.json`、`main.lua` 和整个 `json/` 目录放进
  `<config-dir>/plugins/io.github.yyn0210.json-preview/`，然后在插件管理器中
  批准并启用（首次启用需要批准 `filesystem` 权限）。

## 模块结构

| 模块 | 职责 |
| --- | --- |
| `main.lua` | 清单入口：命令/面板装配、Inspector、折叠与格式化命令、激活 |
| `json/parser.lua` | 严格 RFC 8259 解析器与源码定位（`M.parse`、`compute_line_starts`、`locate`） |
| `json/display.lua` | 显示宽度、字符串显示/编码、节点描述等文本辅助 |
| `json/path.lua` | 路径构建（显示路径带 2 KiB 上限，折叠路径精确）、节点定位、JSONPath 解析与求值 |
| `json/tree.lua` | 折叠状态（内存 + `state.json` 直写）与树形渲染、逐节点 `{ id, args }` 命令 |
| `json/meta.lua` | JSON 元数据统计（`M.statistics`） |

宿主的 `require('json.parser')` 映射到插件根目录下的 `json/parser.lua`；
模块名只允许 `[a-z0-9._]`。

## 使用

| 命令 | 说明 | 快捷键 |
| --- | --- | --- |
| `JSON: Preview` | 打开或刷新右侧预览面板 | `Ctrl+Shift+J` |
| `JSON: Toggle Fold` | 折叠/展开光标所在的对象或数组（预览行点击时按行携带的路径切换） | `Ctrl+Alt+J` |
| `JSON: Toggle Fold All` | 标题栏折叠按钮使用：折叠或展开全部 | — |
| `JSON: Show JSONPath` | 在 Inspector 中显示光标处值的 JSONPath | — |
| `JSON: Extract JSONPath` | 按选区（无选区时用设置）中的表达式提取匹配值 | — |
| `JSON: JSONPath at Cursor or Selection` | 标题栏 JSONPath 按钮使用：有选区则提取，否则显示光标处路径 | — |
| `JSON: Metadata` | 在 Inspector 中显示 JSON 元数据 | — |
| `JSON: Format Document` | 按设置中的缩进宽度格式化当前文档 | — |
| `JSON: Minify Document` | 压缩为单行 JSON | — |
| `JSON: Validate` | 校验并报告类型、键/元素数量或错误位置 | — |

预览、格式化、压缩和校验命令可从“插件”菜单执行；折叠、JSONPath 和元数据
通过标题栏操作按钮或直接点击预览行使用，也可以从命令面板执行。
快捷键可在快捷键编辑器中修改。

### 标题栏操作按钮

预览面板标题栏右侧有三个扁平按钮：

- **Fold All / Expand All**：当前有折叠节点时显示 `Expand All`，否则显示
  `Fold All`；点击切换全部折叠状态，面板保持打开并保留滚动位置。
- **JSONPath**：有选区时按选区中的表达式提取；没有选区时显示光标处值的路径。
- **Metadata**：打开 Inspector 显示 JSON 元数据。

预览标题显示 `文件名 — 根节点摘要`（例如 `sample.json — Object · 15 keys`），
正文不再重复摘要行。

### 节点折叠

- 预览中的对象和数组用 `▾` 表示展开、`▸` 表示折叠，三角位于缩进槽中；
  折叠行会显示隐藏的键或元素数量，例如 `▸ "user": { … 3 keys }`。
- **逐节点点击**：每个可折叠容器行（开括号行与折叠摘要行）都携带
  `command = { id = "json.fold.toggle", args = { path = 折叠路径 } }`，
  点击即切换该节点，无需移动光标；宿主保持面板打开和滚动位置。
- **键盘折叠**：把光标放在某个对象/数组内部，按 `Ctrl+Alt+J`
  （或执行 `JSON: Toggle Fold`），切换光标所在的最深容器。
- 标题栏的 **Fold All / Expand All** 按钮切换全部折叠状态；折叠全部保留根节点
  展开，展开全部清空所有折叠状态。
- 设置 `fold_level` 可以指定打开文档时的初始折叠层级：`0` 全部展开，
  `1` 只展开根，`2` 再展开根的直接子容器，依此类推。
- 折叠状态保存在内存中：同一文档的普通编辑、自动刷新和重新打开面板都不会
  丢失；根节点结构变化或切换文档时重置。
- 折叠状态同时直写到插件数据目录的 `state.json`（申请 `filesystem` 权限的
  唯一用途），重启或 VM 重建后由激活流程读回；文件缺失或损坏时按无折叠启动。

### JSONPath

- 标题栏的 **JSONPath** 按钮：有选区时按选区中的表达式提取；没有选区时显示
  光标处值的路径、类型和值。也可以直接执行 `JSON: Show JSONPath` 或
  `JSON: Extract JSONPath`。
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

`JSON: Metadata` 或标题栏的 **Metadata** 按钮在 Inspector 中显示：值类型
计数、最大深度及其路径、键总数与重复键、空容器、最大对象/数组、字符串字符数与
最长字符串、数字的整数/小数/指数分布及数值范围、顶层键，以及 JSON Lines 的
记录数。重复键最多列出 20 处，其余显示剩余数量。

### Inspector 面板

Inspector 是一个独立的右侧面板，用于显示元数据、JSONPath 查询结果或光标处
路径。宿主同一时间只显示一个插件面板，打开 Inspector 会替换当前的预览面板；
再次执行 `JSON: Preview` 即可切回预览。

- 格式化保留原始键顺序和重复键，不会自动排序；排序只影响预览。
- 格式化/压缩通过 `luban.document.set_text` 修改文档（v2 中变更失败会抛错，
  插件转为通知提示），可撤销并走正常保存流程；完成后光标回到文档开头。
- 面板标题显示当前文件名；切换标签或编辑后自动跟随。

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

- 预览最多读取 512 KiB 源文本、渲染 4,000 行、单行 3,500 字节；超出会截断并提示。
- 单个字符串值在预览中最多显示 200 显示列，超出会以 `…` 截断并标注总字符数；
  格式化与压缩始终保留完整内容。
- 嵌套深度上限为 256 层。
- 折叠状态最多记录 10,000 个节点；超出时需要先展开再折叠。
- 极深的节点路径在**显示**时会截断并附带后缀哈希（上限 2 KiB）；折叠状态使用
  精确路径，不做截断或哈希。
- 严格 JSON：不接受注释、单引号字符串、尾随逗号和 `NaN`/`Infinity`。
- 预览是只读侧栏；格式化/压缩会重写整个文档，不保留原始空白和转义写法。
- 不支持 JSONC/JSON5 的注释与扩展语法。

## 开发

```bash
lua5.4 tests/run.lua            # 解析、渲染、折叠、持久化、JSONPath、元数据与命令测试
python3 scripts/package.py --check
python3 scripts/package.py      # 生成 dist/<id>-<version>.zip
```

测试桩（`tests/run.lua`）模拟 v2 宿主：事件为函数值注册、文档/面板/命令/定时器
为表、变更类 API 返回 nil 并在失败时抛错。发布流程：更新 `plugin.json` 与
`CHANGELOG.md` 的版本，提交并推送 `v<version>` 标签；
`.github/workflows/release.yml` 会运行测试、打包并上传 GitHub Release。
商店目录的 `plugins/<id>.json` 需要记录该产物的 SHA-256 与字节数。

## 许可证

木兰公共许可证第 2 版（MulanPubL-2.0），见 [LICENSE](LICENSE)。
