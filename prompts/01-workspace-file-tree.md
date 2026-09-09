# Phase 1–2 Prompt：工作区、文件树与安全文件操作

完整阅读仓库根目录的产品、架构、设计、路线图、测试计划和 `AGENTS.md`。检查 Phase 0 已通过构建与测试后，实现 `ROADMAP.md` Phase 1；Phase 1 验收通过后再实现 Phase 2。若 Phase 0 不完整，先报告并只补齐必要阻塞项。

必须完成：

- 文件夹选择、security-scoped bookmark、最近工作区和 stale bookmark 恢复。
- `WorkspaceFileSystem` 协议、actor 实现、路径 root 边界检查和可测试依赖注入。
- 惰性文件树、UTType 识别、系统排序、文件名过滤、外部变更合并刷新。
- 新建 Markdown/文件夹、行内重命名、工作区内移动、移到系统废纸篓、Finder 中显示。
- 文件夹、支持文件和 unsupported 文件的基础路由空状态。
- 相关单元、临时目录集成和最小 UI 测试。

实现顺序优先：权限生命周期 → 只读枚举 → 路由 → 外部刷新 → 写操作。所有路径操作先标准化并验证；符号链接不得逃出工作区。不要实现 Markdown 正文编辑、PDFKit 或图片滤镜。

验收时用 Finder/测试代码在应用外创建、修改、重命名和删除文件，确认树能刷新并尽量保留选择/展开状态。实际运行 build/test，记录性能样本与仍有风险。
