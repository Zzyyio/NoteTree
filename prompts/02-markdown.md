# Phase 3 Prompt：Markdown 编辑与冲突安全

阅读所有根目录规范并遵守 `AGENTS.md`。确认 Phase 1–2 测试通过，只实现 `ROADMAP.md` Phase 3。

实现一个完整但克制的 Markdown 闭环：

- 可测试的 `MarkdownDocumentSession`，包含 clean/dirty/saving/conflict/failed 状态。
- UTF-8 读取、源码编辑、编辑/分栏/预览三种模式和核心 Markdown 预览。
- 600 ms 可测试 debounce 自动保存，`⌘S` 立即 flush，切换文件/关闭窗口保护。
- 通过文件系统层原子保存，并使用已加载磁盘版本做 optimistic conflict check。
- 外部改动冲突条：重新加载外部版本、保留本地副本、查看文本差异。
- 查找、undo/redo、加粗/斜体/链接命令和清晰的保存状态。
- 最小崩溃恢复草稿；保存成功后清理，日志不得包含正文。

预览默认不请求远程资源；相对图片解析不得越过工作区。不要引入块编辑器、数据库、双向链接或 AI。若 `TextEditor` 无法可靠实现选区命令和查找，可封装 `NSTextView`，但保持编辑器协议边界。

重点测试快速连续输入、保存进行中继续输入、切换文件、外部同时编辑、写入失败和窗口关闭。完成后运行全量 build/test，并逐项报告 Phase 3 验收结果。
