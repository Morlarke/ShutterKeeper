# 项目状态（交接 / 压缩上下文用）

> 这份文档把项目的全部关键信息固化下来。上下文被压缩、或新开一个对话时，
> 读完它就能接着干，不需要回看聊天记录。

**更新时间**：2026-10-07 ｜ **版本**：beta-0.11 ｜ **自检**：`skctl selftest` 203 项全绿

---

## 一、这是什么

**快门闪选（ShutterKeeper）**：macOS 原生摄影工作流工具，替代 Adobe Bridge 的
**导入 / 批量改名 / 审阅打分**三个环节，并与 Lightroom Classic 互通星级。

| 项 | 值 |
|---|---|
| 技术栈 | Swift 6 + SwiftUI，**零第三方依赖**（系统框架 + 系统 SQLite） |
| 仓库 | https://github.com/Morlarke/ShutterKeeper（私有，MIT） |
| 本地目录 | `/Users/chanse/Documents/Codex/2026-09-28/macos-shutterkeeper-swift-swiftui-adobe-bridge` |
| 作者 | 快门镖局-陈师 · thechengsir@foxmail.com |
| 交付物 | `outputs/快门闪选.app`（release，ad-hoc 签名） |
| 规模 | 70 个 Swift 文件、约 13.7k 行 |

---

## 二、常用命令

```bash
cd "/Users/chanse/Documents/Codex/2026-09-28/macos-shutterkeeper-swift-swiftui-adobe-bridge"

swift build                     # 构建
swift run skctl selftest        # 端到端自检（203 项）
Scripts/build-app.sh release    # 打包 .app（含图标）
git add -A && git commit -m "…" && git push   # 提交（凭据已存钥匙串）
```

**沙盒注意事项**（只有我这边需要，你自己跑不用管）：Codex 的沙盒不允许我改项目的 `.git`，
所以**提交必须由你在终端执行**；构建时要加 `--disable-sandbox --cache-path … --scratch-path …`，
这些可以通过 `SK_SWIFT_FLAGS` 传给 `build-app.sh`。

**验证习惯**：改元数据相关代码后，用 `~/Pictures` 里照片的**副本**跑真实文件验证
（不要动原片），并跑 `skctl selftest`。

---

## 三、代码地图

```
Sources/ShutterKeeperCore/        纯逻辑（无 UI，可单独验证）
├── MediaKind / FileRef / AssetGroup / Pairing    文件类型、配对模型
├── FolderScanner / ExifReader / PhotoMetadata    扫描与元数据读取
├── XMPPacket / XMPSidecar                        XMP 生成与「就地改属性」
├── JPEGMetadataWriter / XMP/TIFFXMPWriter / XMP/PNGXMPWriter / XMP/InPlaceXMP
│                                                 三种容器的原地元数据写入
├── Rotate/Orientation / Rotate/RotateService     非破坏性旋转
├── RatingService / RatingStore / SQLite/…        打分入口与数据库
├── Lightroom/LightroomCatalog / LightroomSync    只读 LR 目录、同步星级
├── Import/…（VolumeScanner / Planner / Executor / History）  导入
├── Rename/…（Planner / Plan / Executor）          批量改名
├── Review/…（Session / RatingFilter / PreviewLoader / ZoomCommand）
├── Shortcuts/…（Action / KeyShortcut / Store）    可自定义快捷键
└── AppPaths / ThumbnailCache / TrashService / FileReplacement

Sources/ShutterKeeperApp/         SwiftUI 界面
├── AppState / ContentView / Theme / Preferences…  全局状态、三标签页、主题、偏好
├── Import/（ImportState / ImportView）
├── Rename/（RenameState / RenameView + 改名弹窗 / RenameBrowser 图标与分栏视图）
├── Review/（ReviewState / ReviewView / Filmstrip / ExifPanel / ZoomableImage /
│            VideoPlayer / FolderBrowser / KeyboardController）
└── Shared/FileActions                             访达显示、简介（⌘I）

Sources/ShutterKeeperCLI/         skctl 诊断工具 + 自检（SelfTest.swift）
Tests/                            swift-testing 单元测试（只有 Xcode 环境能跑）
Scripts/                          build-app.sh（打包）、make-icon.swift、publish-to-github.sh
Assets/AppIcon-source.png         图标源图（换图标只替换它）
```

---

## 四、功能清单

### 全局
三标签页（导入/改名/审阅，⌘⌥1-3 或 ⌘\ 循环）、最近项目、四种背景色（含大图右键切换）、
偏好设置（日期格式/备份路径/缓存位置/EXIF 显示项/背景色/快捷键自定义+冲突检测）。

### 导入（M4）
自动列出外接卷（标注 DCIM）→ 按 EXIF 拍摄日期分组预览 → 项目文件夹 `<日期_项目名>/`
内含 `Photos/` 与 `Videos/` → RAW+JPG 配对、`.xmp` 跟着走 → 冲突询问（目标已存在/之前导入过：
跳过或覆盖）→ 进度条+文件名+剩余时间+可取消 → 可选备份（结构一致）→ 完成后询问清理卡内原文件（进废纸篓）。
导入历史存 SQLite，跨会话识别「这张卡导过没有」。

### 批量改名（M3）
访达式浏览（⌘1 图标 / ⌘2 分栏，列宽可拖）→ 选中文件（⌘/⇧/⌘A/Esc）→ 点「批量改名…」（⌘⇧R）
→ 弹窗里选：日期来源（**拍摄时间 EXIF** 或 **自定义文本**）、日期格式、序号位数（1-6）、
自定义文本（可加到 4 段、可统一套用）、逐日期组填写 → 模板示例实时预览 → 开始改名。
规则：同一天共用一个文本、每组序号从 1 起、视频单独一套序号、RAW+JPG 共用主文件名、
`.xmp/.aae` 等跟着改。目标重名 → 询问（跳过/覆盖进废纸篓）。⌘Z 撤销本次运行内的改名。
**计划覆盖整个文件夹，选中只决定实际改哪些**；已符合模板时弹窗会提示「没有文件需要改名」。

### 审阅（M2）
大图（滚轮缩放/拖拽平移/最大 1:1/双击以点击处为中心切换 1:1 与适应窗口）+ 底部胶片条 +
右侧 EXIF 面板（P 切换、显示项可配）+ 顶部信息条（文件名/星级/序号/日期组/筛选）。
打分 0-5（RAW+JPG 联动、**多选一起打分**、视频不打分）、筛选（≥/≤/= 实时生效，当前被筛掉自动跳下一张）、
←→ 切换、↑↓ 按日期跳组、空格全屏（视频为播放/暂停）、↑↓ 调音量（视频）、删除进废纸篓、
多选（⌘/⇧/⌘A/Esc）、右键菜单（旋转/在访达中显示/文件简介 ⌘I/删除）、左右旋转 ⌘[ ⌘]。
视频用内嵌 AVKit。文件夹导航是访达式分栏，预览区右上角常驻缩放比例、到 1:1 显示「1:1 像素」。

### 与 Lightroom Classic 互通
**Lightroom 默认不把星级写进文件**（「自动将更改写入 XMP」默认关闭），所以：
1. 软件默认**只读** Lightroom 的 `.lrcat`，把 LR 里已有的星级显示出来（顶栏橙色提示「N 张的星级来自 LR 目录」）；
2. 点「写入文件」（或审阅菜单「从 Lightroom 目录导入星级…」）才把星级写进照片，等效于 LR 里按 ⌘S。

---

## 五、关键技术决策（改动前务必先读）

1. **星级写入位置**：JPG → 文件内部 APP1 的 XMP；PNG → iTXt 块；TIFF/DNG → IFD0 的 tag 700；
   专有 RAW → 同名 `.xmp` 侧车；HEIC/PSD/其它图片格式 → 只记软件数据库并明确提示。
2. **一律「就地改属性」**：`XMPPacket.settingValue` 只改那一个字段，绝不重写整份 XMP（LR 的修图设置必须原样保留）。
   必须处理**自闭合** `<rdf:Description … />` —— 曾经因为把它劈成 `/` 和 `>` 生成非法 XML，
   导致只有本软件的能读、LR 读不了。自检里有 XML 合法性断言守着这条。
3. **原地写入靠 padding**：新内容短了就按原长度补空格、长了先吃 padding 里的空格；
   好处是文件大小不变、只动那几十个字节（182 MB 的 TIF 也一样）。PNG 还要重算该块 CRC。
4. **配对模型**：`AssetGroup`（RAW+JPG 视为一张）是打分/筛选/删除/旋转/导入的最小单位；
   视频不与同名照片合并。
5. **旋转非破坏性**：只改 EXIF Orientation（2 字节）或侧车的 `tiff:Orientation`，不重编码像素。
6. **改名两段式搬运**：全部先改成临时名、再改成目标名，避免 A→B、B→C 与互换互相覆盖。
7. **命名冲突**：任何删除/改名/导入的动作都不会静默覆盖，要么询问，要么把旧文件移进废纸篓。
8. **快捷键**：单键 + 组合键统一走 `NSEvent` 本地监听 + `ShortcutStore`（可自定义、有冲突检测）；
   正在输入文字时只放行 ⌘ 组合（⌘Z/X/C/V/A 仍留给输入框）。
9. **存储**：`~/Library/Application Support/ShutterKeeper/{db,cache}`；数据库与缩略图缓存可分别删除，
   删库后可从文件元数据恢复星级。缓存键带文件修改时间，改完元数据自动失效。
10. **图标**：`Scripts/make-icon.swift` 自适应阈值找边界 → 圆角遮罩 → 自己拼 `.icns`
    （沙盒环境里 `iconutil` 不可用），支持深色底与浅色底两种源图。

---

## 六、已知限制 / 待办

* **我这边无法启动 GUI 验证**（沙盒进程连不上 WindowServer），界面改动需要你在本机确认。
* `swift test` 在只有 Command Line Tools 的机器上会卡住（swift-testing 运行器问题），
  用 `skctl selftest` 代替；测试代码本身完整，装了 Xcode 后可跑。
* 未做：PSD/HEIC 内部元数据写入、PNG 旋转（需重编码）、扩展 XMP（>64 KB）、
  分栏视图逐列独立宽度、审阅的对比视图/导出、视频封面自定义。
* 仓库仍是 private；README 还没有界面截图；还没有打 Release。

---

## 七、协作方式

1. 我改本地代码 → 跑 `swift run skctl selftest`（必要时用真实文件副本验证）→ 打包到 `outputs/`；
2. 你在终端 `git add -A && git commit -m "…" && git push`（提交信息我会给）；
3. GitHub 上的 CI（`.github/workflows/build.yml`）会自动构建 + 跑自检 + 产出 `.app` 附件；
4. 我的 GitHub MCP 凭据目前**只读**（不能建仓库/写文件），涉及仓库的写操作要你来做。
