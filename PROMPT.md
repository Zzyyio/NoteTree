# NoteTree 首次构建 Prompt

你正在构建一个原生 macOS 应用 NoteTree。仓库根目录包含 `PRODUCT.md`、`ARCHITECTURE.md`、`DESIGN.md`、`ROADMAP.md`、`TEST_PLAN.md` 和 `AGENTS.md`。

开始前完整阅读这些文件，并把 `AGENTS.md` 视为强制执行规则。先检查仓库现状和 Git 状态，然后只完成 `ROADMAP.md` 的 Phase 0；不要提前实现文件树、Markdown、PDF 或图片功能。

本次目标：

1. 建立可由 Xcode 打开和构建的 macOS 14+ Swift 6 工程。
2. 创建主 App、单个 `NavigationSplitView` 窗口、Welcome 占位、Settings 场景和必要的 String Catalog。
3. 建立 `App/Core/Features/UI` 目录边界、最小依赖容器和 `os.Logger` 分类，但不要创建大量空壳类型。
4. 创建 unit test 与 UI test targets，并加入至少一个启动测试和一个 Core 示例测试。
5. 开启 App Sandbox 与 User Selected File Read/Write；不申请网络 entitlement。
6. 写明准确的 build/test 命令，并实际运行验证。

工程创建策略：

- 如果仓库已有可用 `.xcodeproj`/`.xcworkspace`，在其上最小修改，不另建工程。
- 如果仓库为空，创建标准 Xcode project；可使用已存在的项目生成配置，但不要在未获同意时引入运行时第三方依赖。
- Bundle ID 暂用 `com.example.NoteTree`，并在 README 标注发布前需替换；不要写入个人 Team ID。

完成前：

- 运行 Debug build 和 tests。
- 检查 git diff，确认没有签名证书、用户路径、DerivedData 或生成缓存。
- 更新 `ROADMAP.md` 中 Phase 0 的实际状态与验证记录，不得把 Phase 1 标为完成。
- 按 `AGENTS.md` 的完成报告格式回复。

如果当前环境不能创建或运行 Xcode 工程，仍需完成能安全完成的仓库结构和配置，并明确列出阻塞原因、未验证项和用户在 Mac 上应运行的准确命令；不得伪造测试结果。
