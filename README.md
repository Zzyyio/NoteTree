# NoteTree

NoteTree 是一个原生 macOS、本地优先的文件型笔记应用。工作区就是用户选择的普通文件夹；Markdown、PDF 和图片保持原格式，可被 Finder、Git、iCloud Drive 或其他应用直接访问。

## 当前状态

项目已实现文件管理、Markdown、PDF 阅读以及图片编辑的核心闭环，可用 Xcode 打开。2026-10-20 的开发补充了非 PDF 功能，当前包含：

- `NoteTree` macOS App target。
- `NoteTreeTests` 单元测试 target。
- `NoteTreeUITests` UI 测试 target。
- `App/Core/Features/UI` 源码边界、依赖容器和分类日志。
- `NavigationSplitView` 主窗口、欢迎页与 Settings 场景。
- 文件夹选择、security-scoped bookmark、最近工作区与失效权限重新授权。
- 受工作区 root 边界保护的文件系统 actor：惰性树、过滤、类型路由、隐藏/包/.git/构建目录排除，以及符号链接逃逸防护。
- `NSFilePresenter` 外部变更观察；刷新后保留可用的展开状态与选中项。
- 新建空白 Markdown/文件夹、行内重命名、工作区内移动与移到系统废纸篓；所有操作均在文件系统 actor 内重新校验工作区边界、根目录保护、名称冲突与符号链接。
- 侧边栏的“新建”菜单、项目右键菜单与“在 Finder 中显示”；移动仅通过文件树内直接拖放完成，新建、重命名和移动接入系统 Undo。
- 仅限工作区内的文件树拖放移动、复制文件 URL 到 macOS 剪贴板，以及异步读取的文件信息面板（类型、相对路径、大小、修改时间和文件夹直接子项数）。
- 英文和简体中文 String Catalog。
- App Sandbox 与 User Selected File Read/Write entitlement；无网络 entitlement。

- Markdown 原生源码编辑、选区加粗/斜体/链接、系统查找、分栏/只读预览、表格与安全本地图片、自动保存、草稿恢复及外部冲突处理。
- 图片降采样、缩放/平移、旋转/翻转、裁剪与比例、曝光/对比度/饱和度、蓝色画笔标记、撤销/重做、恢复原图。
- 图片手动保存使用版本检查与协调原子替换；PNG 副本保存在原目录，名称冲突时不覆盖。多帧与无法安全写回的格式只能导出当前帧副本。
- 实用设置：外观、编辑字号/换行/自动保存、隐藏文件、名称排除模式和 JPEG 质量。文件排除规则在重新打开工作区后生效。
- 独立多窗口、当前窗口菜单、窗口工作区和选择恢复、后退/前进，以及非 PDF 未保存内容的关闭与退出保护。

## 当前限制与发布准备

- Markdown 是轻量本地预览，不承诺完整 CommonMark；图片目前要求独占一行，复杂嵌套列表和带转义管道的表格仍有限制。远程图片不自动加载。
- 图片副本当前统一导出 PNG；GIF/TIFF 多帧只预览/导出首帧。原格式保存仅对安全的单帧 PNG/JPEG/HEIC/TIFF 开放。
- 图片编辑历史为当前会话历史，重新打开不会保留撤销栈。裁剪和标记主要使用鼠标，完整辅助技术操作尚需人工验收。
- 本轮未改动 PDF；PDF 仍按路线图列出的独立待办与验证状态处理。
- 真实 HEIC/广色域、iCloud/外接盘、40 MP 图片内存表现及跨系统兼容矩阵未完成。此次没有运行饱和或长时间压力测试。
- 发布前将 Bundle Identifier 改为自有标识，在 Xcode Signing & Capabilities 选择开发团队；保持 App Sandbox 与 Hardened Runtime。使用 Archive → Distribute App 完成 Developer ID 签名与公证，私钥/证书不进入仓库。
- 应用没有账号、遥测或网络权限；正文保留为普通文件，设置与书签存储在应用容器。

## 开发与验证

使用 `NoteTree.xcodeproj` 在 Xcode 中打开工程，scheme 选择 `NoteTree`。命令行可运行：

```bash
xcodebuild -project NoteTree.xcodeproj \
  -scheme NoteTree \
  -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData \
  build

xcodebuild -project NoteTree.xcodeproj \
  -scheme NoteTree \
  -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData \
  test
```

完整的 Debug、Release 和测试验证可一键运行：

```bash
./Scripts/verify.sh
```

Bundle Identifier 当前为占位值 `com.example.NoteTree`，发布前必须替换；工程未写入个人 Team ID。

## 建议阅读顺序

1. `PRODUCT.md`：产品目标、功能边界和验收标准。
2. `ARCHITECTURE.md`：技术选型、模块划分、数据流和风险控制。
3. `DESIGN.md`：界面、交互、快捷键和状态设计。
4. `ROADMAP.md`：按依赖关系拆分的实现阶段。
5. `TEST_PLAN.md`：自动化测试和人工验收清单。
6. `AGENTS.md`：Codex 在仓库中必须遵守的开发规则。
7. `PROMPT.md`：首次让 Codex 启动项目时使用的总提示词。
8. `prompts/`：每个阶段可单独使用的提示词。

## 已确定的产品基线

- 平台：macOS 14 Sonoma 及以上。
- 技术：Swift 6、SwiftUI，必要处桥接 AppKit。
- 数据：本地文件夹，不使用专有笔记数据库保存正文。
- 文本：第一版只把 Markdown (`.md`) 作为可编辑笔记格式。
- PDF：阅读、搜索、缩略图、旋转及常用批注。
- 图片：浏览、缩放、旋转、裁剪、基础色彩调整及标记。
- 布局：左侧文件树，右侧编辑/预览区域；可选检查器。
- 同步：由 iCloud Drive、Dropbox、Git 等文件系统工具负责；第一版不自建账户和云服务。

## 规格包使用方式

`AGENTS.md` 位于仓库根目录，Codex 会把它视为项目级指令。

然后把 `PROMPT.md` 的内容作为第一次构建任务交给 Codex。每完成一个阶段，运行 `TEST_PLAN.md` 对应的测试，再使用 `prompts/` 中下一个阶段的提示词。

## 工作名称

文档暂用 **NoteTree**。正式开发前可全局替换为最终产品名、Bundle Identifier 和 Team ID；这些名称不影响架构。
