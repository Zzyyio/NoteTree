# NoteTree 测试计划

## 1. 测试原则

- 数据安全相关逻辑必须先有测试再扩展功能。
- 单元测试不依赖用户真实 Documents 目录。
- 集成测试为每个用例创建独立临时工作区，并在测试结束清理。
- UI 测试通过 launch argument 注入测试工作区，避免自动操纵系统文件选择器。
- 大文件样本由脚本生成或在测试时构造，不提交含隐私的真实资料。

## 2. 单元测试

### File type 与路径安全

- 大小写扩展名、无扩展名、错误扩展名但 UTType 正确。
- `..`、符号链接、alias、相似前缀目录不能逃出 root。
- 相对路径 ID 在工作区整体移动后保持逻辑稳定。
- localized 排序、文件夹优先和隐藏文件规则。

### File system

- 读取返回内容和版本。
- expected version 匹配时原子保存成功。
- expected version 不匹配时返回 conflict，原文件不变。
- 临时写入失败、替换失败、无权限和磁盘空间错误可恢复。
- 重命名同名、跨卷移动和移入废纸篓错误被正确映射。

### Markdown

- UTF-8、中文、emoji、CRLF/LF。
- debounce 只保存最后版本；显式 save 会 flush。
- 保存期间继续输入不会错误清除 dirty。
- 外部修改 + 本地 dirty 进入 conflict。
- 预览不加载远程资源；相对图片路径不得越界。

### PDF

- annotation 创建、属性变更、删除和 undo/redo。
- 旋转保存后页数和内容仍有效。
- 加密、受限、损坏 PDF 进入正确只读/错误状态。
- 保存失败不破坏原件。

### Image

- EXIF orientation 1–8 显示方向正确。
- crop/rotate/flip 顺序确定且输出尺寸正确。
- 调整参数边界和重置。
- alpha、color profile 和 metadata 的保留策略。
- 多帧 TIFF/GIF 和 RAW 不进行危险覆盖。

## 3. 集成测试

- 打开临时工作区 → 扫描 → 展开 → 选择 → 路由。
- App 运行时外部创建、修改、重命名、删除文件，树与编辑器状态正确。
- 新建/重命名/移动后磁盘与树一致。
- security bookmark provider 返回 stale/denied 时走恢复流程。
- Markdown 保存后由第二个独立文件读取器验证内容。
- PDF 保存后重新实例化 `PDFDocument` 验证批注存在。
- 图片导出后由 `CGImageSource` 验证格式、尺寸与可解码性。

## 4. UI 测试

- 欢迎页打开已注入工作区。
- 键盘展开文件树并打开三种支持文件。
- 新建 Markdown、输入、等待自动保存、重启后内容存在。
- 重命名冲突显示行内错误且可取消。
- 外部冲突 banner 的三个动作可操作。
- PDF 添加批注、保存、重新打开。
- 图片裁剪、撤销、另存副本。
- 关闭 dirty 文档出现正确确认流程。
- 菜单命令与焦点上下文正确启用/禁用。

## 5. 人工兼容矩阵

| 维度 | 样本 |
| --- | --- |
| macOS | 14、15、当前最新稳定版 |
| 处理器 | Apple Silicon；Intel 若仍承诺支持则补测 |
| 文件位置 | 本地、iCloud Drive、外接盘、只读目录 |
| 工作区规模 | 10、1,000、5,000、20,000 项 |
| Markdown | 空文件、中文、1 MB、长行、表格、相对图片 |
| PDF | 1 页、500 页、100 MB、扫描件、加密、带签名 |
| 图片 | JPEG、PNG alpha、HEIC、TIFF、广色域、大于 40 MP |

## 6. 性能与稳定性

- 用 signpost 测量工作区首次可交互、目录展开、文件打开、保存和图片滤镜。
- Instruments 检查 Main Thread、Leaks、Allocations 和 File Activity。
- 连续切换 100 个文件，确认旧任务取消、内存能回落。
- 运行 30 分钟 PDF 滚动与图片缩放压力测试。
- 模拟保存时应用终止，确认原文件可打开，临时文件能被安全清理或恢复。

## 7. 发布阻断级别

- P0：原文件损坏、静默覆盖冲突、越界删除/移动、权限数据泄漏。任何一个都阻断发布。
- P1：核心格式无法打开或保存、稳定崩溃、工作区无法恢复。阻断发布。
- P2：单个工具失效、明显性能退化但有替代路径。默认修复后发布。
- P3：视觉和低频体验问题。可记录后进入后续版本。

## 8. 每阶段完成命令

项目建立后，在 `AGENTS.md` 的占位处写入真实 scheme。标准验证形态：

```bash
xcodebuild -project NoteTree.xcodeproj \
  -scheme NoteTree \
  -destination 'platform=macOS' \
  build

xcodebuild -project NoteTree.xcodeproj \
  -scheme NoteTree \
  -destination 'platform=macOS' \
  test
```

若采用 workspace，统一改为 `-workspace`，不要让文档与 CI 使用两套命令。
