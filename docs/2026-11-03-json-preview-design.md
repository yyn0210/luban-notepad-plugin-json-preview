# JSON 预览插件设计

日期：2026-11-03
状态：已实现

## 目标

为 Luban Notepad 提供一个 JSON 预览插件。插件以纯 Lua 单文件实现，运行在宿主
沙箱内；预览显示在插件面板中，随活动文档编辑自动刷新，并以树状结构展示 JSON
数据、语法配色、错误位置和重复键提示。插件同时提供格式化、压缩和校验命令。

## 非目标

- 不实现 JSON 编辑器和交互式折叠；预览只读。
- 不支持 JSONC/JSON5 注释、单引号、尾随逗号等扩展语法。
- 不解析 JSON Schema，不做路径查询或字段搜索。
- 不访问文件系统、网络或子进程；不申请任何权限。
- 不注入 HTML/WebView 或自定义控件。

## 兼容与降级

- 宿主 API 主版本保持 `1`；`api_version` 为 1。
- 旧宿主忽略 `width`、`refresh`、`style`、`indent`、`spans`、`role`，使用每行的
  `text` 纯文本回退，并手动刷新。
- 富文本、自动刷新和 `luban.panel.open` 需要 Luban Notepad 1.0.0-preview.2
  及以上；格式化/压缩/校验只依赖 `luban.get_document` 和
  `luban.set_document_text`。

## 解析器

`main.lua` 内置严格 RFC 8259 递归下降解析器，不依赖 `luban.json.decode`：

- 保留对象键的原始顺序和重复键；重复键记录首次出现的 pair。
- 字符串解码覆盖 `\" \\ \/ \b \f \n \r \t`、`\uXXXX` 和 UTF-16 代理对；
  拒绝未转义控制字符、非法转义、未配对代理项和非法 UTF-8。
- 数字按 JSON 文法校验，保留原始字面量（例如 `1e10`、`1.0`、`-0`），不做浮点
  转换，避免精度丢失。
- 错误以 `{ message, pos }` 表抛出，由面板转换为行号、列号和上下文。
- 嵌套深度上限 256，避免 Lua 栈溢出；源文本上限 512 KiB。
- UTF-8 在整篇入口校验一次，避免逐字符串重复校验。

## 渲染

- 面板 `json.preview.panel`：右侧、宽度 720、`refresh: edit`。
- 每行使用 `style = "code"` 和 `spans`：
  - 键：`property`
  - 字符串：`string`；数字：`number`；布尔值：`boolean`；`null`：`constant`
  - 标点：`punctuation` / `punctuation.bracket`
  - 缩进、重复键和截断说明使用 `muted`
- 对象和数组按设置缩进展开；空容器显示为 `{}` / `[]`。
- 顶部 muted 摘要：根类型、键/元素/字符数量、源字节数、重复键数量。
- 重复键追加 `duplicate key (first at line N)`。
- 超长字符串在 200 显示列处截断并追加总字符数；数字最多显示 80 字节。
- 面板行上限 4,000，单行上限 3,500 字节（宿主硬上限 4 KiB 和 5,000 行）。

## 错误展示

无效 JSON 时显示：

1. `Invalid JSON: <原因>`
2. `at line L, column C`
3. 错误行及上一行的源码摘要，行号 gutter
4. 插入符 `^`

长行以插入符为中心开窗，两端加 `…`；制表符展开为 4 个空格；CJK 按显示宽度
对齐。源文本被 512 KiB 截断时追加提示。

## JSON Lines

整篇解析失败且 `json_lines` 开启时，逐非空行独立解析。仅当所有非空行都合法且
至少两行时进入 JSON Lines 模式；否则回退到整篇错误。每个记录显示源行号和类型
摘要，记录内重复键照常标注。

## 命令与设置

- `json.preview` / `JSON: Preview` / `Ctrl+Shift+J` / `when: edit_text`
- `json.format` / `JSON: Format Document`
- `json.minify` / `JSON: Minify Document`
- `json.validate` / `JSON: Validate`
- 设置：`indent`（1–8，默认 2）、`sort_keys`（仅预览，默认 false）、
  `json_lines`（默认 true）。
- 格式化/压缩只接受 512 KiB 以内的单个 JSON 值，保留键顺序和重复键；格式化使用
  设置中的缩进并追加结尾换行，压缩输出单行。两者通过 `luban.set_document_text`
  修改文档，可撤销。

## 安全

- `permissions: []`；不声明文件系统、网络或进程权限。
- 所有输入按不可信数据处理；解析器和渲染器不执行输入内容。
- 指令上限由宿主保护；512 KiB 文档实测解析约 1,340 万条 Lua 指令，低于
  5,000 万上限。

## 测试

- `tests/run.lua`：27 组 Lua 5.4 测试，覆盖解析、转义、数字、错误、深度、
  重复键、渲染角色、排序、JSON Lines、截断、命令、旧宿主降级和 fixture。
- `scripts/package.py --check`：清单、API 版本、主文件路径和确定性 zip。
- 真实宿主 headless 验证：安装插件、打开 JSON 示例、触发预览、截图核对。
- 商店：`validate.py --download` 校验产物哈希与大小，应用内安装验证。

## 默认值

- 插件 ID：`io.github.yyn0210.json-preview`
- 名称：`JSON Preview`；商店 `zh-CN` 名称“JSON 预览”
- 版本：`1.0.0`；许可证：`MulanPubL-2.0`
- 商店：提交到 `yyn0210/luban-notepad-store` 的 `main`
