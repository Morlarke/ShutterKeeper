# 发布到 GitHub

项目已经准备好直接发布：纯 Swift + SwiftUI，**零第三方依赖**，
克隆下来 `swift build` 就能构建，`swift run skctl selftest` 能跑完整自检。

我验证过：把将来会提交的文件（1.9 MB 源码）单独复制到空目录，
从零构建成功、180 项自检全过、`Scripts/build-app.sh` 能打出带图标的 `.app`。

---

## 一键发布（推荐）

```bash
cd "/Users/chanse/Documents/Codex/2026-09-28/macos-shutterkeeper-swift-swiftui-adobe-bridge"
Scripts/publish-to-github.sh                 # 仓库名 ShutterKeeper，公开
# 或者：Scripts/publish-to-github.sh ShutterKeeper private
```

脚本会：初始化仓库 → 检查有没有超 5MB 的误提交文件 → 提交 → 用 `gh` 建仓库并推送。

> 注意：这一步必须在**你自己的终端**里跑。Codex 的沙盒不允许改动项目的 `.git`，
> 也没有你的 GitHub 凭据。

## 手动发布

1. 装 GitHub CLI（可选，但最省事）：`brew install gh && gh auth login`
2. 跑上面的脚本；或者完全手动：

```bash
cd "/Users/chanse/Documents/Codex/2026-09-28/macos-shutterkeeper-swift-swiftui-adobe-bridge"
git init
git config user.name "快门镖局-陈师"
git config user.email "thechengsir@foxmail.com"
git add -A
git commit -m "快门闪选 beta0.1：导入 / 批量改名 / 审阅打分，与 Lightroom Classic 互认星级"
git branch -M main

# 在 https://github.com/new 建一个空仓库（不要勾选 README / .gitignore / license），然后：
git remote add origin https://github.com/<你的用户名>/ShutterKeeper.git
git push -u origin main
```

首次推送要求认证：用户名填 GitHub 用户名，密码处粘贴
[Personal Access Token](https://github.com/settings/tokens)（勾 `repo` 权限）。

---

## 提交内容说明

会被提交：

```
Package.swift
Sources/            Core（元数据/导入/改名/审阅逻辑）+ App（SwiftUI 界面）+ CLI（skctl）
Tests/              swift-testing 单元测试
Scripts/            build-app.sh（打包 .app）、make-icon.swift（生成图标）、publish-to-github.sh
Assets/             应用图标源图
.github/workflows/  CI：构建 + 单元测试 + 自检 + 产出 .app
README.md           功能、设计决策、各模块说明
PUBLISH.md          本文件
```

被忽略（`.gitignore`）：`build/`、`work/`、`outputs/`、`.build/`、`.DS_Store`。

我检查过：**代码与文档里没有任何个人路径或隐私信息**，README 里的示例都是
`~/Pictures`、`/路径/文件夹` 这类通用写法。

---

## 开源协议

本项目采用 **MIT**（见 [LICENSE](LICENSE)）：可以自由使用、修改、分发、商用，
只需保留版权声明与许可证原文。版权归 快门镖局-陈师 所有。

## 还需要你决定的事

### 仓库名与描述（建议）

* 名字：`ShutterKeeper`（ASCII 更通用；中文名「快门闪选」放在描述里）
* 描述：`macOS 原生摄影工作流工具：SD 卡导入 / 批量改名 / 审阅打分，与 Lightroom Classic 互认星级`
* Topics：`macos`、`swift`、`swiftui`、`photography`、`lightroom`、`xmp`、`metadata`、`raw`、`avif`…

---

## 发布之后的两点提醒

**CI 会自动跑起来。** `.github/workflows/build.yml` 在每次 push / PR 时：
构建 → `swift test` → `swift run skctl selftest`（180 项检查）→ 打包 `.app` 并作为构建产物上传，
可以在 Actions 页面直接下载。

**关于分发的 .app。** 打包出来的是 ad-hoc 签名（没有 Apple 开发者证书），
别人从 Release 下载后会看到「无法打开，因为无法验证开发者」的提示。两种办法：

* 在 Release 说明里写清楚：右键点图标 → 打开；或执行
  `xattr -dr com.apple.quarantine "/Applications/快门闪选.app"`
* 或者干脆建议使用者自己 `Scripts/build-app.sh` 构建（源码发布的话最干净）

想要正式签名/公证，需要 Apple Developer 账号（$99/年），那是另一个话题。
