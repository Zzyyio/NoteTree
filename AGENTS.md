# AGENTS.md

本文件是 Codex 在 NoteTree 仓库中的项目级执行规则。它的要求适用于整个仓库；子目录若有更具体的 `AGENTS.md`，只可补充局部约束，不得降低数据安全要求。

## 1. 开始任务前

1. 阅读 `PRODUCT.md`、`ARCHITECTURE.md`、`DESIGN.md`、`ROADMAP.md` 和 `TEST_PLAN.md`。
2. 检查当前 Git 状态，保留用户已有修改，不覆盖无关文件。
3. 确认本次任务属于哪个 Phase，只实现该阶段和其必要依赖。
4. 先定位现有实现和测试，再修改；不要平行造第二套服务或 Store。
5. 若需求会改变文件格式、写入策略、sandbox 权限或删除语义，先停止并说明风险。

## 2. 不可违反的约束

- 用户正文、PDF 和图片必须保留为普通文件；不得迁入专有数据库。
- 不自建后端，不添加账户、遥测、广告或网络请求。
- 所有工作区路径在操作前验证，绝不允许逃出已授权 root。
- 删除使用系统废纸篓；禁止永久递归删除用户文件。
- 写入使用协调访问和原子替换；禁止直接覆盖唯一原件的大文件。
- 检测到外部冲突时禁止静默覆盖。
- bookmark data、文件正文和完整敏感路径不得进入日志。
- 文件递归、PDF 保存、图片渲染不得阻塞主线程。
- 不用 `fatalError`、强制解包或 `try!` 处理可由用户文件触发的情况。
- 不以 `@unchecked Sendable` 或关闭严格并发检查掩盖设计问题。

## 3. 技术与风格

- Swift 6，macOS 14+，SwiftUI 优先；只在系统能力不足时桥接 AppKit。
- 类型与文件使用 UpperCamelCase；函数与属性 lowerCamelCase。
- 一个文件优先放一个主要类型；文件名与主要类型一致。
- UI 类型标记 `@MainActor`；I/O 通过 actor 或结构化并发隔离。
- 依赖用协议和构造器/环境注入，不新增业务 singleton。
- 用户可见字符串放 String Catalog，不在 View 中散落硬编码文本。
- 使用 `os.Logger`，不使用 `print` 作为正式日志。
- 注释解释“为什么”和不变量，不重复代码字面含义。
- 保持函数短小，但不要为每三行代码创建无意义抽象。

## 4. 依赖政策

- 首选 Apple frameworks：SwiftUI、AppKit、PDFKit、Core Image、ImageIO、UniformTypeIdentifiers、OSLog。
- 新增第三方依赖前，在任务说明中列出用途、许可证、二进制/源码体积、维护状况和原生替代方案。
- 未获明确同意，不增加运行时第三方包。
- 不执行来源不明的安装脚本，不提交构建产物、签名材料或开发机绝对路径。

## 5. 实现工作流

1. 为行为变化补充或更新测试。
2. 实现最小闭环，不提前做未来 Phase。
3. 构建并运行相关测试。
4. 检查主线程 I/O、并发警告、权限范围和失败回滚。
5. 运行全量测试；若环境无法运行，明确给出未验证内容和准确命令。
6. 更新相关文档和 `ROADMAP.md` 状态，但不要把计划写成已经完成。

## 6. 测试要求

- 业务逻辑用 temporary directory 或 in-memory test double。
- 每个文件写入功能至少测试：成功、权限失败、目标冲突、外部版本改变。
- 每个删除/移动功能测试 root 边界和符号链接逃逸。
- 异步测试不得依赖任意 sleep；使用 controllable clock、expectation 或事件流。
- UI 测试使用注入工作区，不自动确认系统授权面板。
- 修复 bug 时先添加能复现问题的回归测试。

## 7. 构建与验证

项目建立后以仓库实际 scheme 更新这里；默认命令：

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

如果只改纯 Core 模块，可先运行定向测试，但完成前仍需运行全量 test。不要通过删除测试、降低 warning 设置或禁用 sandbox 来获得绿色构建。

## 8. 完成报告格式

每次完成任务，简要报告：

- 完成了什么。
- 修改了哪些关键文件。
- 运行了哪些验证及结果。
- 尚未验证或存在什么风险。
- 下一步应进入哪个 Roadmap 条目。

不要声称“完全完成”，除非对应验收标准和测试确实通过。
