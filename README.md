# NoteTree

NoteTree 是一个原生 macOS、本地优先的文件型笔记应用。工作区就是用户选择的普通文件夹；Markdown、PDF 和图片保持原格式，可被 Finder、Git、iCloud Drive 或其他应用直接访问。

## 当前状态

项目已完成 Phase 2 的安全文件操作闭环，可用 Xcode 打开。当前包含：

- `NoteTree` macOS App target。
- `NoteTreeTests` 单元测试 target。
- `NoteTreeUITests` UI 测试 target。
- `App/Core/Features/UI` 源码边界、依赖容器和分类日志。
- `NavigationSplitView` 主窗口、欢迎页与 Settings 场景。
- 文件夹选择、security-scoped bookmark、最近工作区与失效权限重新授权。
- 受工作区 root 边界保护的文件系统 actor：惰性树、过滤、类型路由、隐藏/包/.git/构建目录排除，以及符号链接逃逸防护。
- `NSFilePresenter` 外部变更观察；刷新后保留可用的展开状态与选中项。
- 新建空白 Markdown/文件夹、行内重命名、工作区内移动与移到系统废纸篓；所有操作均在文件系统 actor 内重新校验工作区边界、根目录保护、名称冲突与符号链接。
- 侧边栏的“新建”菜单、项目右键菜单、目标文件夹选择器与“在 Finder 中显示”；新建、重命名和移动接入系统 Undo。
- 英文和简体中文 String Catalog。
- App Sandbox 与 User Selected File Read/Write entitlement；无网络 entitlement。

Markdown、PDF、图片和不支持文件仍只进入基础内容路由占位。Markdown 正文编辑、保存、PDF 与图片工具严格留待后续阶段；Phase 2 不会覆盖已有用户文件，删除仅调用系统废纸篓。

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
