# Phase 7 Prompt：完成度与发布准备

阅读所有根目录规范并遵守 `AGENTS.md`。确认 Phase 0–6 的退出标准和全量测试都已有证据，只实现 `ROADMAP.md` Phase 7。

完成：

- Settings、窗口恢复、多窗口、菜单和快捷键的最终整合。
- 简体中文/英文 String Catalog 完整性，VoiceOver、全键盘、Reduce Motion 和高对比度检查。
- 所有空状态、加载、权限、文件不存在、冲突、保存失败和受限格式错误文案及恢复动作。
- 5,000/20,000 文件工作区、1 MB Markdown、100 MB/500 页 PDF、40 MP 图片的性能与内存测试。
- Debug/Release build、unit/integration/UI tests、30 分钟压力测试和数据损坏恢复演练。
- App Sandbox、Hardened Runtime、entitlements、隐私说明、签名占位和已知限制审计。
- README 的准确构建/测试/发布说明，并把 `ROADMAP.md` 状态更新为实际结果。

不要顺带实现 Beta 功能、联网、账号、OCR、AI 或新依赖。逐项核对 `PRODUCT.md` 第 13 节验收标准和 `TEST_PLAN.md` 的 P0/P1 阻断项；任何未验证项都必须明确列出，不得为了发布删除测试或降低安全设置。
