# 更新日志

## 1.1.0 — 2026-11-03

- 节点折叠：对象/数组显示 `▾`/`▸` 标记，折叠行显示隐藏的键或元素数量。
  - 新增 `JSON: Toggle Fold`（`Ctrl+Alt+J`），折叠/展开光标所在容器。
  - 新增 `JSON: Fold All` 和 `JSON: Expand All`。
  - 新增 `fold_level` 设置，控制打开文档时的初始折叠层级。
  - 折叠状态在编辑和自动刷新时保留，根结构变化或切换文档时重置。
- JSONPath：
  - 新增 `JSON: Show JSONPath`，显示光标处值的路径、类型和值。
  - 新增 `JSON: Extract JSONPath`，按选区或 `jsonpath` 设置求值并列出匹配值。
  - 支持子属性、下标、通配符、递归下降、切片和联合；不支持的过滤表达式会明确报错。
  - 新增 `show_paths` 设置，在预览行尾附加 JSONPath 注释。
- JSON 元数据：新增 `JSON: Metadata` 和 Inspector 面板，显示类型计数、最大深度、
  键与重复键、空容器、最大对象/数组、字符串统计、数字分布与范围、顶层键，
  以及 JSON Lines 记录数。
- 新增 `json.inspector.panel` 面板，用于显示元数据、JSONPath 查询结果和光标处路径。
- 预览和 JSON Lines 均支持折叠、路径注释与元数据分析。

## 1.0.1 — 2026-11-03

- 修复格式化/压缩在光标位于文档末尾附近时可能触发宿主 “invalid selection”
  错误的问题：现在显式把选区设为文档开头（0, 0）。

## 1.0.0 — 2026-11-03

首个版本。

- 右侧面板中的树状 JSON 预览，使用当前语法主题为键、字符串、数字、布尔值、
  `null` 和标点着色。
- 严格 RFC 8259 解析器：保留键顺序与重复键，支持全部字符串转义和代理对。
- 错误定位：原因、行号/列号、上下文源码和插入符；为尾随逗号、注释、单引号、
  前导零、未配对代理项等常见错误提供专门提示。
- 重复键在预览中标注首次出现位置。
- JSON Lines 自动识别：每行一个合法 JSON 值时按记录逐条预览并标注源行号。
- 编辑后自动刷新（约 150ms 防抖），并保持面板滚动位置。
- 命令：`JSON: Preview`（`Ctrl+Shift+J`）、`JSON: Format Document`、
  `JSON: Minify Document`、`JSON: Validate`。
- 设置：`indent`、`sort_keys`、`json_lines`。
- 旧宿主降级为纯文本回退和手动刷新；插件不需要任何权限。
