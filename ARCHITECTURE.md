# NoteTree 技术架构

## 1. 技术基线

| 项目 | 选择 |
| --- | --- |
| 最低系统 | macOS 14 |
| 语言 | Swift 6，开启严格并发检查 |
| UI | SwiftUI；文件选择、PDF、部分文本/图片交互桥接 AppKit |
| PDF | PDFKit |
| 图片 | ImageIO + Core Image + Core Graphics；标记可用 PencilKit/AppKit overlay |
| Markdown | 源码编辑器 + 本地预览；MVP 不引入 Web 端编辑器 |
| 持久化 | 普通文件 + UserDefaults + 可重建缓存 |
| 项目 | Xcode project；运行时依赖优先 Apple frameworks |
| 测试 | Swift Testing 或 XCTest；UI 使用 XCUITest |

第三方包不是绝对禁止，但任何新增包都必须先记录：用途、许可证、体积、维护状态、Apple 原生方案为何不足。MVP 默认零运行时第三方依赖。

## 2. 总体结构

采用 feature-oriented 分层，避免把全部状态塞进单一 `ObservableObject`：

```text
NoteTree/
├── App/
│   ├── NoteTreeApp.swift
│   ├── AppCommands.swift
│   └── DependencyContainer.swift
├── Core/
│   ├── FileSystem/
│   ├── Persistence/
│   ├── Models/
│   ├── Security/
│   └── Utilities/
├── Features/
│   ├── Workspace/
│   ├── FileTree/
│   ├── MarkdownEditor/
│   ├── PDFViewer/
│   ├── ImageEditor/
│   ├── Search/
│   └── Settings/
├── UI/
│   ├── Components/
│   └── Resources/
└── Tests/
```

每个 Feature 尽量包含 `Models`、`Views`、`ViewModels` 或 `Store`。Core 不依赖 Feature；Feature 可依赖 Core；Feature 之间通过小型协议和路由模型协作。

## 3. 状态模型

### 3.1 核心类型

```swift
struct WorkspaceID: Hashable, Codable, Sendable { let rawValue: UUID }

struct Workspace: Identifiable, Sendable {
    let id: WorkspaceID
    let rootURL: URL
    var displayName: String
}

struct FileNode: Identifiable, Hashable, Sendable {
    let id: FileNodeID       // 基于标准化相对路径 + 工作区 ID
    let url: URL
    let relativePath: String
    let kind: FileKind
    var children: [FileNode]?
    var metadata: FileMetadata
}

enum FileKind: Sendable {
    case folder
    case markdown
    case pdf
    case image(ImageFormat)
    case unsupported
}

enum EditorKind: Hashable, Sendable {
    case markdown(URL)
    case pdf(URL)
    case image(URL)
    case unsupported(URL)
    case folder(URL)
}
```

不要把 `PDFDocument`、`NSImage`、`NSView` 等非 `Sendable` 对象放入跨 actor 的值模型。它们应由 `@MainActor` 控制器持有，或封装在明确隔离的对象中。

### 3.2 单一事实来源

- 磁盘文件是正文与媒体的事实来源。
- `WorkspaceStore` 管理当前工作区、选择、展开路径和导航历史。
- `FileTreeStore` 只保存当前展示快照；它可由磁盘重新构建。
- 每个打开的编辑器拥有自己的 session，包含 dirty、undo、磁盘版本和冲突状态。
- UI 设置由 `SettingsStore` 管理并映射到 `UserDefaults`。
- 搜索索引和缩略图是缓存，删除后必须能重建。

## 4. 文件系统层

### 4.1 协议

```swift
protocol WorkspaceFileSystem: Sendable {
    func children(of directory: URL) async throws -> [FileEntry]
    func readData(at url: URL) async throws -> VersionedData
    func writeData(_ data: Data, to url: URL, expected: FileVersion?) async throws -> FileVersion
    func createDirectory(at url: URL) async throws
    func moveItem(from: URL, to: URL) async throws
    func trashItem(at url: URL) async throws
}
```

实现为 `actor LocalWorkspaceFileSystem`。所有公开操作先验证 URL：标准化后必须仍位于当前工作区根目录内，并拒绝通过 `..`、符号链接或别名逃逸。

### 4.2 协调和原子写入

- 通过 `NSFileCoordinator` 协调读取、写入和移动，兼容 iCloud Drive 等 file presenter。
- 保存流程：同目录生成唯一临时文件 → 写入并同步错误 → 用协调 replacement 替换目标 → 删除临时残留。
- 保留原扩展名和合理的 POSIX 权限；不要自作主张修改创建日期。
- 写入前比较 `FileVersion`。版本可由 resource identifier、modification date、size 组合而成，不依赖单一时间戳。
- PDF 和图片的大文件保存不得先把多份完整数据长期留在内存中。

### 4.3 监控

- MVP 可使用根目录 `DispatchSourceFileSystemObject` 作为“需要重新扫描”的信号。
- 对 iCloud/协调文件访问，结合 `NSFilePresenter` 获取更可靠通知。
- 事件必须去抖并合并；后台构建新快照后在主 actor 做最小状态替换。
- 监控事件不是变更详情的事实来源；收到事件后比较目录快照。
- 选择与展开状态使用相对路径恢复。文件被重命名且无法匹配时选择其最近父目录。

### 4.4 Security-scoped bookmark

- bookmark 数据只存应用容器，不写入日志或工作区。
- 每次访问前调用 `startAccessingSecurityScopedResource()`，生命周期结束必须成对停止。
- 用引用计数 token 或作用域对象管理访问，避免过早停止。
- 解析出 stale bookmark 时，在权限仍可使用时刷新；无法刷新则请求用户重新选择。
- 单元测试通过 bookmark provider 协议替身，不把系统面板塞入业务逻辑。

## 5. 文件树

- 初次只扫描一级，文件夹展开时惰性加载子层级；为过滤/搜索建立独立后台枚举任务。
- 排序默认“文件夹在前 + localizedStandardCompare”。
- `FileNodeID` 不应仅使用绝对 URL；绝对路径可能因工作区移动而改变。
- 大目录枚举在后台 actor 执行，并支持取消旧任务。
- UI 推荐 `List(selection:)` + `DisclosureGroup`/递归 row；如果 SwiftUI 在大树上性能不足，再用 `NSOutlineViewRepresentable`，不要过早桥接。
- 重命名验证空字符串、路径分隔符、重复名称和根目录保护。
- 拖放只允许工作区内安全移动；外部文件拖入在 Beta 再实现，避免“移动还是复制”语义混乱。

## 6. 文档会话和冲突

通用状态机：

```text
loading -> clean -> dirty -> saving -> clean
                 \-> conflict
loading/saving -> failed -> retrying
```

`DocumentSession` 保存：

- `url`
- `loadedVersion`
- `isDirty`
- `saveState`
- `externalChangeState`
- `lastSuccessfulSave`

切换选择不会立即销毁 dirty session。应用先 flush 自动保存；失败时保留 session 并阻止静默丢弃。窗口关闭通过异步确认流程等待保存或用户选择。

冲突处理：

- 只有磁盘变更：自动重新加载或提示，取决于文件类型和用户设置。
- 只有本地 dirty：正常保存。
- 两者都有：进入 conflict，停止自动保存。
- Markdown 可显示逐行差异；PDF/图片提供版本选择和“本地另存副本”，MVP 不做二进制合并。

## 7. Markdown 编辑器

- `MarkdownDocumentSession` 在后台读取/编码，在 `@MainActor` 更新文本状态。
- 源码编辑 MVP 可从 SwiftUI `TextEditor` 开始；需要查找、选区命令与 undo 精准控制时，封装 `NSTextView`。
- 为避免后续重写，文本编辑视图应通过协议暴露 `text`、selection、focus 与 command，而非让 Feature 直接依赖具体视图。
- 预览使用受控渲染管线。可先用 Apple `AttributedString(markdown:)` 支持核心语法；表格和代码块不足时，再引入经过评估的 Markdown parser。
- 本地图片路径以笔记所在目录为基准解析，解析后仍必须位于工作区或获得独立授权。
- 预览中的远程资源 MVP 默认不加载，防止打开笔记时泄漏网络请求。

## 8. PDF 模块

- `PDFViewRepresentable` 包装 `PDFView`，`PDFEditorController` 为 `@MainActor`。
- controller 负责 document 生命周期、selection、缩放、页码、查找、批注工具和 undo。
- 用 `PDFThumbnailView` 或自建 lazy thumbnail inspector；避免提前生成所有高分辨率页图。
- 批注工具状态与 `PDFView` 手势分离。自由文本和形状先由按钮创建默认 annotation，再允许移动/调整。
- 保存前检查 locked、encrypted、permissions 和 write capability。
- PDF 保存至临时 URL，再经文件系统层替换。不要直接依赖 `PDFDocument.write(to:)` 覆盖唯一原件。
- 修改数字签名 PDF 可能使签名失效；检测到签名或受限权限时默认只读并提示另存副本。

## 9. 图片模块

- 用 `CGImageSource` 读取尺寸、帧数、UTType、orientation、color profile 和 metadata。
- 交互预览生成合理尺寸的降采样 `CIImage`；操作参数以 value model 保存。
- 编辑管线顺序固定并测试：orientation normalization → crop → rotate/flip → tonal adjustments → markup composite → encode。
- 只有 export/save 时处理完整分辨率。保存副本默认沿用源格式；源格式不支持安全写回时建议 PNG/JPEG/HEIC。
- `ImageEditRecipe` 应可 Codable，方便 undo/redo 和未来 sidecar，但 MVP 不必默认持久化 sidecar。
- 每次参数变化不生成完整位图；缓存键由源版本 + recipe + preview size 组成。

## 10. 路由与依赖注入

`EditorRouter` 只根据已识别的 `FileKind` 选择 View。UTType 识别顺序：目录 → 内容类型/resource values → 扩展名 fallback。不要只比较字符串后缀。

`DependencyContainer` 注入：

- `WorkspaceFileSystem`
- `BookmarkStore`
- `FileTypeDetector`
- `ThumbnailCache`
- `Clock` / debounce scheduler
- `Logger`

测试以 in-memory 或 temporary-directory 实现替换。不要使用全局 singleton 作为业务依赖。

## 11. 并发

- View 与 AppKit/PDFKit 控制器：`@MainActor`。
- 文件枚举、读写协调、缩略图、图片渲染：独立 actor / structured task。
- 所有长任务支持取消；选择新文件时取消旧预览任务。
- 禁止 `Task.detached` 捕获 UI 状态；优先 child tasks。
- 不用 `@unchecked Sendable` 掩盖问题，除非有文档化不变量和专门测试。
- 主线程不执行目录递归、完整 PDF 数据写入或全分辨率滤镜。

## 12. 错误模型与日志

定义面向用户的 `AppError`，至少区分：permissionDenied、bookmarkStale、fileMissing、unsupportedFormat、decodeFailed、readFailed、writeFailed、nameConflict、externalConflict、outOfWorkspace、cancelled。

- 底层错误保留为诊断信息，但用户文案给出下一步动作。
- 用 `os.Logger` 分类：workspace、filesystem、markdown、pdf、image。
- 公开日志只写路径的最后一段或哈希，不记录正文与 bookmark data。
- 用户主动取消不是错误，不弹警报。

## 13. 缓存

- `NSCache` 用于内存缩略图和预览。
- 磁盘缓存放 `Caches`，键包含工作区 ID、相对路径、文件版本和渲染参数。
- App Support 保存最近工作区、崩溃恢复草稿和可重建搜索索引。
- 缓存失败不能阻止原文件打开；版本改变立即视为 miss。

## 14. 建议 Xcode targets

- `NoteTree`：主应用。
- `NoteTreeCore`：可测试的文件系统、模型和编辑 recipe；可为 local Swift package 或 framework target。
- `NoteTreeTests`：单元/集成测试。
- `NoteTreeUITests`：端到端 UI 测试。

如果项目规模较小，MVP 可以先用单一 App target + Test targets，但目录和访问控制仍按上述边界组织；不要为“架构纯洁”制造大量空 target。

## 15. 构建配置

- Bundle ID 占位：`com.example.NoteTree`，首次构建时替换。
- App Sandbox：开启。
- User Selected File：Read/Write。
- Hardened Runtime：Release 开启。
- 网络 entitlement：MVP 不需要。
- CI 运行 Debug build、unit tests 和 SwiftFormat/SwiftLint（仅在项目明确加入后）。
- 不把 Team ID、签名证书、绝对开发机路径提交到仓库。
