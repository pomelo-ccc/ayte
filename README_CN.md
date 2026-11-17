# Ayte

[English](README.md)

**Ayte** 是面向 **Google Antigravity (`agy`)** 的原生桌面工作台与轻量 IDE，基于 Flutter 与 macOS / Windows / Linux 原生能力构建。

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
   flutter build macos --release
   ```

## 致谢与开源协议

本项目基于开源软件 [BaoCode](https://github.com/baocode-dev/baocode) 衍生改造，遵循相同的开源许可证发布，详见 [LICENSE](LICENSE)。
