# aibar

[English](#english) · [简体中文](#简体中文)

一个为 macOS 设计的本地 AI 使用情况仪表盘。aibar 把 Codex 的本地会话记录、配额和活动状态收进刘海下方与状态栏：需要时展开查看，不需要时保持安静。

> 版本 0.1.7 · macOS 13 Ventura 或更高版本 · Apple Silicon

![aibar dashboard](docs/images/dashboard-en.png)

## 简体中文

### 功能一览

- **刘海仪表盘**：将指针移到 MacBook 刘海区域，或点击状态栏中的趋势图标，即可展开仪表盘。它展示今日与本月的 API 等价费用、Token、最近会话、会话／周配额、每日使用热图、模型明细、常用项目和工具调用／文件改动统计。
- **状态栏入口**：左键状态栏图标可直接显示或隐藏仪表盘；右键可开关运行胶囊、开始截图或退出应用。
- **运行状态胶囊**：在刘海下方显示 Codex 正在进行的工作。每个胶囊显示项目、模型、当前阶段、耗时和上下文 Token；悬停可展开多个并行任务，点击可回到对应的 Codex 对话。任务确认完成后会短暂显示结果，避免把内部回合切换误报为完成。
- **为 AI 协作优化的截图**：按 `fn + 4` 后拖拽选择区域，进入标注编辑器。可用方框、箭头、圆形、自由画笔和“文字 → 箭头”标记；每个标记自动编号，删除后会重新排序。支持选中删除、撤销、选择颜色、复制到剪贴板和保存图片，便于把明确、可引用的视觉反馈交给 AI 或同事。
- **中英文界面**：首次启动跟随 macOS 语言；在仪表盘标题栏的语言菜单中选择“中文”或 “English”，选择会在下次启动后保留。
- **分享卡片**：从仪表盘生成可分享的使用情况卡片，并选择不同的视觉样式。
- **安全自动更新**：启动时及之后每 6 小时检查 GitHub Releases。右键状态栏图标后选择“检查更新”，若有可用版本，会在 SHA-256 校验完成后自动安装并重启。更新包还必须和当前应用拥有相同的 Bundle ID 与 Developer ID 签名，才能保留 macOS 的屏幕录制等隐私授权；签名不一致时会拒绝自动替换，避免静默失去授权。
- **本地优先**：Codex 的会话与活动数据在本机读取、聚合。aibar 不上传提示词、响应内容或文件内容；模型定价信息会从公开价格页读取并在本地缓存，显示金额为 API 等价估算，不是账单。
- **主动预加载**：启动（包括首次安装后首次打开）会立即读取本地会话，并并行刷新模型定价；无需先打开仪表盘即可尽快看到完整数据。

### 安装

#### Homebrew（推荐）

首次安装需要添加此项目作为 tap：

```bash
brew tap zszbyzsz/aibar https://github.com/zszbyzsz/aibar.git
brew install --cask aibar
```

若 Homebrew 同时报出其他 Cask（例如 `gcloud-cli` 或 `libreoffice`）不可读，通常是
Homebrew 程序与 Cask API 元数据版本不一致，并非 aibar 的依赖。请先把 Homebrew 的
`ORIGIN` 恢复为官方仓库并修复这些 Cask，再重试安装：

```bash
git -C "$(brew --repository)" remote set-url origin https://github.com/Homebrew/brew
brew update-reset "$(brew --repository)"
brew update
brew reinstall --cask gcloud-cli libreoffice
brew install --cask aibar
```

可用 `brew config` 确认 `ORIGIN` 与 Homebrew 版本；若你有意使用第三方镜像，请确保
它同步的是完整且与当前 Cask API 兼容的 Homebrew 版本。`brew update-reset` 会重置
Homebrew 主仓库中的本地提交和未提交修改；若你维护过这些修改，请先备份。

更新：

```bash
brew update
brew upgrade --cask aibar
```

#### 直接下载安装包

在 [Releases](https://github.com/zszbyzsz/aibar/releases) 下载 `aibar-0.1.7.zip`，解压后将 `aibar.app` 拖入“应用程序”文件夹并打开。

请使用同一 Developer ID 签名的正式发布版，以便自动更新后保持屏幕录制授权。若 macOS 阻止首次启动，请在 Finder 中按住 Control 点击应用并选择“打开”；若仍被隔离，可执行：

```bash
xattr -dr com.apple.quarantine /Applications/aibar.app
```

#### 从源码安装并设为登录项

```bash
git clone https://github.com/zszbyzsz/aibar.git
cd aibar/aibar
./scripts/install.sh
```

脚本会构建 Release 应用、安装到 `~/Applications/aibar.app`，并创建当前用户的 LaunchAgent，使应用登录后自动运行。卸载：

```bash
cd aibar/aibar
./scripts/uninstall.sh
```

### 使用方法

1. 启动 aibar；它只在状态栏与刘海附近显示，不会占用 Dock。
2. 悬停刘海或点击状态栏图标，查看仪表盘；右键图标可访问运行胶囊和截图命令。
3. 在仪表盘标题栏选择语言，或点击分享按钮生成使用概览卡片。
4. 按 `fn + 4` 选择截图区域，在编辑器中添加按顺序编号的标记后复制或保存。

### 数据与隐私

- 默认读取 `~/.codex` 中的本地会话和活动索引；可以通过 `CODEX_HOME` 指向其他本地目录。
- 活动监视仅读取必要元数据，不读取会话标题或消息预览。
- 本地缓存与临时截图会留在本机。退出或关闭编辑器时，截图捕获的临时源文件会被删除。
- 更新检测只向 GitHub Releases API 请求公开版本元数据，不携带会话或项目数据；通过摘要校验的更新压缩包保存在本机缓存目录中。
- Codex 之外的 Claude Code、Trae CN 扫描器包含在代码中；当前仪表盘界面默认聚焦 Codex。

### 本地构建与测试

```bash
cd aibar
swift build
swift test
./scripts/build-app.sh
open dist/aibar.app
```

发布自动更新版本时，请用同一个 Developer ID 证书签名：

```bash
SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/build-app.sh
```

---

## English

### Overview

aibar is a local-first macOS dashboard for AI coding activity. It turns Codex session records, quota data, and live activity into a compact view beneath your MacBook notch and a convenient menu-bar control.

### Features

- **Notch dashboard** — Hover over the notch or click the menu-bar trend icon to open a dashboard with today/month API-equivalent cost, tokens, recent-session usage, session and weekly limits, daily usage heatmap, model breakdown, top projects, and tool/file-change totals.
- **Menu-bar controls** — Left-click to show or hide the dashboard. Right-click to toggle the activity capsule, start a screenshot, or quit.
- **Live activity capsule** — A floating capsule under the notch reports active Codex work: project, model, phase, elapsed time, and context tokens. Hover to expand simultaneous conversations; click a capsule to return to its Codex conversation. Completion notices are confirmed across polls so an internal turn boundary is not presented as a finished task.
- **Screenshots made for AI feedback** — Press `fn + 4`, select a region, then annotate it with rectangles, arrows, ovals, freehand pen marks, or text-to-arrow callouts. Marks are automatically numbered and renumber after deletion. Select/delete, undo, color selection, copy, and save are all built in, making visual feedback precise and easy to reference.
- **Chinese and English UI** — The initial language follows macOS. Switch between 中文 and English from the dashboard header; the choice persists across launches.
- **Share cards** — Generate a shareable usage summary card with selectable styles.
- **Safe automatic updates** — Check GitHub Releases at launch and every six hours. Choose **Check for Updates** from the menu-bar icon’s right-click menu to download, verify, install, and relaunch when an update is available. Automatic replacement requires the same bundle ID and Developer ID signing identity, preserving macOS privacy consent such as Screen Recording; a mismatched signature is refused rather than silently changing that identity.
- **Local first** — Session and activity data are read and aggregated on your Mac. aibar does not upload prompts, responses, or file contents. Public pricing data may be fetched and cached locally; displayed prices are API-equivalent estimates, not invoices.
- **Eager loading** — At launch, including the first launch after installation, aibar immediately reads local sessions and refreshes model pricing in parallel, so the dashboard does not need to be opened before data begins loading.

### Install

#### Homebrew (recommended)

```bash
brew tap zszbyzsz/aibar https://github.com/zszbyzsz/aibar.git
brew install --cask aibar
```

If Homebrew also reports unrelated casks (for example, `gcloud-cli` or
`libreoffice`) as unreadable, its program and Cask API metadata are usually out
of sync; those casks are not aibar dependencies. Restore Homebrew's official
upstream and repair the affected casks before retrying:

```bash
git -C "$(brew --repository)" remote set-url origin https://github.com/Homebrew/brew
brew update-reset "$(brew --repository)"
brew update
brew reinstall --cask gcloud-cli libreoffice
brew install --cask aibar
```

Use `brew config` to verify the `ORIGIN` and Homebrew version. If you
intentionally use a third-party mirror, ensure it provides a complete Homebrew
version compatible with the current Cask API. `brew update-reset` discards
local committed and uncommitted changes in the Homebrew repository, so preserve
any intentional changes first.

To update:

```bash
brew update
brew upgrade --cask aibar
```

#### Download the app

Download `aibar-0.1.7.zip` from [Releases](https://github.com/zszbyzsz/aibar/releases), unzip it, drag `aibar.app` to Applications, and open it.

Use a release signed consistently with the same Developer ID to preserve Screen Recording consent through automatic updates. If macOS blocks the first launch, Control-click the app in Finder and choose **Open**. If it remains quarantined:

```bash
xattr -dr com.apple.quarantine /Applications/aibar.app
```

#### Build from source and launch at login

```bash
git clone https://github.com/zszbyzsz/aibar.git
cd aibar/aibar
./scripts/install.sh
```

This builds the release app, installs it at `~/Applications/aibar.app`, and registers a per-user LaunchAgent. To uninstall:

```bash
cd aibar/aibar
./scripts/uninstall.sh
```

### Usage

1. Launch aibar. It runs as a menu-bar/notch app and does not occupy the Dock.
2. Hover over the notch or click the menu-bar icon to inspect the dashboard. Right-click the icon for the capsule and screenshot commands.
3. Pick a language in the dashboard header or use the share button to create a usage card.
4. Press `fn + 4`, select a region, annotate it with numbered callouts, then copy or save the result.

### Data and privacy

- aibar reads local sessions and activity metadata from `~/.codex` by default; set `CODEX_HOME` to use another local directory.
- The activity monitor deliberately reads only the metadata it needs, never conversation titles or message previews.
- Local caches and screenshot work stay on your Mac. The temporary source captured for the editor is removed when capture processing ends.
- Update checks request only public release metadata from the GitHub Releases API and never include session or project data. Digest-verified update archives remain in the local cache directory.
- Claude Code and Trae CN scanners are included in the codebase, while the current dashboard experience is focused on Codex.

### Build and test

```bash
cd aibar
swift build
swift test
./scripts/build-app.sh
open dist/aibar.app
```

For a release that can update without resetting its privacy identity, sign
every version with the same Developer ID certificate:

```bash
SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/build-app.sh
```

## License

[MIT](LICENSE)
