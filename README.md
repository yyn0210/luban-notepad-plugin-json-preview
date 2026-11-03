# JSON Preview for Luban Notepad

在 Luban Notepad 的右侧面板中预览当前 JSON 文档。插件是单文件 Lua，运行在编辑器
沙箱内，只读取当前文档，不需要文件系统、网络或子进程权限。

A tree-style JSON preview for [Luban Notepad](https://github.com/yyn0210/luban-notepad).
The plugin is a single sandboxed Lua file and requests no permissions.

## 功能

- 严格 RFC 8259 解析：对象、数组、字符串（含 `\uXXXX` 和代理对）、数字、
  `true`/`false`/`null`；保留原始键顺序和重复键。
- 树状缩进预览，键、字符串、数字、布尔值、`null` 和标点使用当前语法主题配色。
- 错误定位：显示原因、行号/列号、上下文源码和插入符；常见错误有专门提示
  （尾随逗号、注释、单引号、前导零、未配对代理项等）。
- 重复键提示：保留全部重复键，并在预览中标注首次出现的位置。
- 自动识别 JSON Lines：整篇不是单个 JSON 值、但每个非空行都是合法 JSON 时，
  按记录逐条预览并标注源行号。
- 编辑时自动刷新（约 150ms 防抖）；也可以点面板上的“刷新”。
- 命令：预览、格式化、压缩、校验。
- 旧版宿主自动降级：忽略富文本字段，显示纯文本回退和手动刷新。

## 兼容性

| 宿主版本 | 体验 |
| --- | --- |
| Luban Notepad 1.0.0-preview.2 及以后 | 着色预览、自动刷新、可调面板宽度 |
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
| `JSON: Format Document` | 按设置中的缩进宽度格式化当前文档 | — |
| `JSON: Minify Document` | 压缩为单行 JSON | — |
| `JSON: Validate` | 校验并报告类型、键/元素数量或错误位置 | — |

命令可从命令面板或“插件”菜单执行；快捷键可在快捷键编辑器中修改。

- 格式化保留原始键顺序和重复键，不会自动排序；排序只影响预览。
- 格式化/压缩通过 `luban.set_document_text` 修改文档，可撤销并走正常保存流程。
- 面板标题显示当前文件名；切换标签或编辑后自动跟随。
- 面板上“刷新”可手动重算，“关闭”关闭面板。

旧版宿主没有 `luban.panel.open`：预览命令会提示从“插件”菜单打开
“JSON Preview”面板。

## 设置

| 键 | 类型 | 默认 | 说明 |
| --- | --- | --- | --- |
| `indent` | number | `2` | 预览和格式化时每级缩进的空格数（1–8） |
| `sort_keys` | boolean | `false` | 仅在预览中按字母顺序排列对象键 |
| `json_lines` | boolean | `true` | 整篇不是单个 JSON 值时，尝试按 JSON Lines 预览 |

## 限制

- 预览最多读取 512 KiB 源文本、渲染 4,000 行；超出会截断并提示。
- 单个字符串值在预览中最多显示 200 显示列，超出会以 `…` 截断并标注总字符数；
  格式化与压缩始终保留完整内容。
- 嵌套深度上限为 256 层。
- 严格 JSON：不接受注释、单引号字符串、尾随逗号和 `NaN`/`Infinity`。
- 预览是只读侧栏；格式化/压缩会重写整个文档，不保留原始空白和转义写法。
- 不支持 JSONC/JSON5 的注释与扩展语法。

## 开发

```bash
lua5.4 tests/run.lua            # 解析、渲染、命令与面板测试
python3 scripts/package.py --check
python3 scripts/package.py      # 生成 dist/<id>-<version>.zip
```

发布流程：更新 `plugin.json` 与 `CHANGELOG.md` 的版本，提交并推送 `v<version>`
标签；`.github/workflows/release.yml` 会运行测试、打包并上传 GitHub Release。
商店目录的 `plugins/<id>.json` 需要记录该产物的 SHA-256 与字节数。

## 许可证

木兰公共许可证第 2 版（MulanPubL-2.0），见 [LICENSE](LICENSE)。
