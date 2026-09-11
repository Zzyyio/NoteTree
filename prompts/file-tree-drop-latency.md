# 文件树拖放卡顿

## 现象

工作区内把文件拖到另一个文件夹，松手后文件树会停一拍，再突然出现在目标里。不是 Finder 那种图标跟着进文件夹。

已经改成乐观移动：先改树，再 `moveItem`，失败回滚。磁盘侧是对的，UI 仍然卡。

## 原因

1. **松手时并没有立刻改树。** `performDrop` 先 `return true`（拖影没了），再异步 `loadDataRepresentation` 把 token 读回来，然后才 `completeDrop` → `applyVisibleMove`。`draggedNodeID` 拖开始就已经在 Store 里，这一圈对应用内拖放是多余的。用户看到的空窗发生在乐观更新之前。

2. **自己的 move 仍会触发全量可见树 refresh。** `WorkspaceChangeMonitor` 对根目录任何变化 debounce 350ms 后重建所有已展开目录，一次性替换 `rootChildren`。递归 `List` + `DisclosureGroup` 会整树抖一下。现有抑制有两个洞：`markInternalMutation()` 写在 `moveItem` 成功之后，但 presenter 在协调写入过程中就会响；窗口内只吞第一次回调，一次 move 常有多发事件，第二次仍全量 refresh。

3. **目标未展开时乐观插入是空操作。** `insertNode` 遇到 `children == nil` 直接 return，源节点却已删掉。文件从树上消失；随后 refresh 又可能被吞掉，要等点开目标才看见。`optimisticMoveNode` 还把文件夹的 `children` 设成 `nil`，已展开文件夹会再收合一次。

4. **行身份是相对路径。** 移动后 `FileNodeID` 变了，SwiftUI `ForEach` 当成删旧行、插新行。这解释了「跳过去」而不是滑过去。不要为修手感改这个身份模型。

同盘 `rename` 本身很快。卡的不是搬文件，是空窗 + 整树重建。

## 可行方案

**A. 松手同步改树**  
`performDrop` 用已有 `activeDragToken` / `draggedNodeID` 在同一调用栈里做 `applyVisibleMove`。`loadDataRepresentation` 不再当闸门。`moveItem` 仍在之后异步跑，失败回滚。

**B. 内部 mutation 用时间窗口，不要「吞一次」**  
从乐观插入起算（不要等 `moveItem` 返回）打开抑制窗口；窗口内所有 `refreshAfterExternalChange` 都跳过。`moveItem` 结束后再留一小段，覆盖 coordinator 尾部通知。失败则立刻关掉窗口。真正的外部变化（Finder / iCloud）窗口外仍走全量 `refresh()`。不要删 monitor。

**C. 目标未展开也要能插入**  
`children == nil` 时不要 no-op：乐观地建成含该节点的 children，或先保证有数组再插入。移动文件夹时保留 `source.children`。

**D. 减抖动，可选**  
乐观更新只发布一次树状态；成功后路径没变就不要再 `refresh()` / `applySuccessfulMove`。不要改 `FileNodeID`，不要上 `NSOutlineView`。

优先做 A + B + C。D 有余力再做。
