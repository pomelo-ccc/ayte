# Ayte

[English](README.md) · [最新版本下载 (Releases)](https://github.com/pomelo-ccc/ayte/releases/latest)

**Ayte** 是面向 **Google Antigravity (`agy`)** 的原生桌面工作台与轻量 IDE，基于 Flutter 与 macOS / Windows / Linux 原生能力构建。

## 下载安装

直接前往 [GitHub Releases](https://github.com/pomelo-ccc/ayte/releases/latest) 或点击下方对应平台安装包下载（当前版本 `v2.0.2`）：

| 平台 | 架构 | 直接下载 |
| --- | --- | --- |
| **macOS** | Apple Silicon (M1 / M2 / M3 / M4) | [Ayte-2.0.2-arm64.dmg](https://github.com/pomelo-ccc/ayte/releases/download/v2.0.2/Ayte-2.0.2-arm64.dmg) |
| **macOS** | Intel (x86_64) | [Ayte-2.0.2-x64.dmg](https://github.com/pomelo-ccc/ayte/releases/download/v2.0.2/Ayte-2.0.2-x64.dmg) |
| **Windows** | x64 (Windows 10 / 11) | [Ayte-2.0.2-setup.exe](https://github.com/pomelo-ccc/ayte/releases/download/v2.0.2/Ayte-2.0.2-setup.exe) |
| **Windows** | ARM64 | [Ayte-2.0.2-setup-arm64.exe](https://github.com/pomelo-ccc/ayte/releases/download/v2.0.2/Ayte-2.0.2-setup-arm64.exe) |
| **Linux** | x64 (Ubuntu / Debian `.deb`) | [Ayte-2.0.2-linux-amd64.deb](https://github.com/pomelo-ccc/ayte/releases/download/v2.0.2/Ayte-2.0.2-linux-amd64.deb) · [.tar.gz](https://github.com/pomelo-ccc/ayte/releases/download/v2.0.2/Ayte-2.0.2-linux-amd64.tar.gz) |
| **Linux** | ARM64 (Ubuntu / Debian `.deb`) | [Ayte-2.0.2-linux-arm64.deb](https://github.com/pomelo-ccc/ayte/releases/download/v2.0.2/Ayte-2.0.2-linux-arm64.deb) · [.tar.gz](https://github.com/pomelo-ccc/ayte/releases/download/v2.0.2/Ayte-2.0.2-linux-arm64.tar.gz) |

> **macOS 首次运行说明**：打开 `.dmg` 将 `Ayte` 拖入 `Applications` 后，若系统提示「已损坏 / 无法验证开发者」（未开启 Apple 公证签名），请在终端执行一次以下命令即可正常打开：
> ```bash
> xattr -cr /Applications/Ayte.app
> ```
> 同时请确保本机已安装并登录 **Antigravity CLI (`agy`)**（终端可执行 `agy --version`）。

## 核心特性

- **原生对接 Antigravity CLI (`agy`)**：通过常驻多轮 `stream-json` 进程直接复用本机已登录的 `agy` 账号与环境（自动识别 `~/.gemini/bin/agy`、`~/.local/bin/agy` 等），完整保留子智能体与后台任务状态，免去每轮冷启动鉴权耗时。
- **保留自定义 API 供应商（内置内核）**：除 `agy` 外，支持在「设置 → 模型」中配置自定义 Anthropic / OpenAI 协议供应商并通过内置内核运行。
- **完全独立的数据与身份隔离**：独立 Bundle ID（`dev.ayte.desktop`）、独立应用配置目录（`~/Library/Application Support/ayte`）与独立会话记录存储（`~/.ayte/projects/`），彻底移除 Claude Code CLI 依赖，不读取或污染 `~/.claude`。
- **原生对接 `~/.gemini` Customize 体系**：在「设置 → 自定义」与会话记忆胶囊中直接管理 Antigravity 的全局（`~/.gemini/config/`）与项目级（`.agents/`、`GEMINI.md`、`AGENTS.md`）Skills、Plugins、Rules、MCP Servers 与 Hooks。
- **高密度桌面工作台体验**：内置代码编辑器与 Diff 审阅、多标签终端、会话时间轴回放（Session Replay）、实时耗时秒表、Stash 灵感暂存、macOS 顶部灵动岛拖拽投喂与盯盘小窗、以及端到端加密手机互联。

## 本地运行与构建

1. 确保本机已安装并登录 **Antigravity CLI (`agy`)**（终端可执行 `agy --version`）。
2. 开发运行：
   ```bash
   flutter pub get
   flutter run -d macos
   ```
3. 打包 Release 应用：
   ```bash
   dart run tool/build_macos.dart    # macOS (.dmg / .zip)
   dart run tool/build_windows.dart  # Windows (-setup.exe)
   sh tool/package_linux_deb.sh      # Linux (.deb / .tar.gz)
   ```

## 致谢与开源协议

本项目基于开源软件 [BaoCode](https://github.com/baocode-dev/baocode) 衍生改造，遵循相同的开源许可证发布，详见 [LICENSE](LICENSE)。
