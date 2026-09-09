# Phase 6 Prompt：图片浏览与非破坏编辑

阅读所有根目录规范并遵守 `AGENTS.md`。确认 Phase 0–5 通过，只实现 `ROADMAP.md` Phase 6。

实现：

- 用 ImageIO 识别 PNG/JPEG/HEIC/TIFF/GIF，读取 orientation、帧数、色彩配置和 metadata。
- 降采样预览、平移、以指针为中心缩放、适合窗口和 100%。
- Codable/value-semantic `ImageEditRecipe`：方向归一化、裁剪、旋转/翻转、曝光、对比度、饱和度、标记合成。
- 固定且有测试的渲染顺序；交互用预览尺寸，保存才渲染原分辨率。
- crop UI、调整 inspector、undo/redo、恢复原图、保存、另存副本。
- 尽可能保留 ICC profile 和安全 metadata；JPEG 默认质量 0.9 且可配置。
- 多帧 TIFF/GIF、RAW 或无法保证安全写回的格式只读或要求另存为兼容格式。

保存前不得修改原文件。每个保存流程必须测试成功、权限失败、目标冲突和外部版本改变。用超大图片检查主线程和内存。完成后运行全量 build/test，并按测试计划报告格式、尺寸、透明度、orientation 与 metadata 结果。
