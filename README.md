# Ayte

[中文说明](README_CN.md) · [Latest Release](https://github.com/pomelo-ccc/ayte/releases/latest)

**Ayte** is a native desktop workbench and IDE for **Google Antigravity (`agy`)**, built with Flutter and native macOS/Windows/Linux integrations.

## Download & Install

Grab the prebuilt installer for your platform from [GitHub Releases](https://github.com/pomelo-ccc/ayte/releases/latest) (current version `v2.0.2`):

| Platform | Architecture | Direct Download |
| --- | --- | --- |
| **macOS** | Apple Silicon (M1 / M2 / M3 / M4) | [Ayte-2.0.3-arm64.dmg](https://github.com/pomelo-ccc/ayte/releases/download/v2.0.3/Ayte-2.0.3-arm64.dmg) |
| **macOS** | Intel (x86_64) | [Ayte-2.0.3-x64.dmg](https://github.com/pomelo-ccc/ayte/releases/download/v2.0.3/Ayte-2.0.3-x64.dmg) |
| **Windows** | x64 (Windows 10 / 11) | [Ayte-2.0.3-setup.exe](https://github.com/pomelo-ccc/ayte/releases/download/v2.0.3/Ayte-2.0.3-setup.exe) |
| **Windows** | ARM64 | [Ayte-2.0.3-setup-arm64.exe](https://github.com/pomelo-ccc/ayte/releases/download/v2.0.3/Ayte-2.0.3-setup-arm64.exe) |
| **Linux** | x64 (Ubuntu / Debian `.deb`) | [Ayte-2.0.3-linux-amd64.deb](https://github.com/pomelo-ccc/ayte/releases/download/v2.0.3/Ayte-2.0.3-linux-amd64.deb) · [.tar.gz](https://github.com/pomelo-ccc/ayte/releases/download/v2.0.3/Ayte-2.0.3-linux-amd64.tar.gz) |
| **Linux** | ARM64 (Ubuntu / Debian `.deb`) | [Ayte-2.0.3-linux-arm64.deb](https://github.com/pomelo-ccc/ayte/releases/download/v2.0.3/Ayte-2.0.3-linux-arm64.deb) · [.tar.gz](https://github.com/pomelo-ccc/ayte/releases/download/v2.0.3/Ayte-2.0.3-linux-arm64.tar.gz) |

> **macOS First Launch Note**: After dragging `Ayte` into `Applications`, if Gatekeeper blocks opening an ad-hoc signed build, run this once in Terminal:
> ```bash
> xattr -cr /Applications/Ayte.app
> ```
> Make sure **Antigravity CLI (`agy`)** is installed and signed in on your machine (`agy --version`).

## Highlights

- **First-Class Antigravity CLI (`agy`) Engine**: Persistent multi-turn `stream-json` sessions over your local `agy` installation (`~/.gemini/bin/agy` or `~/.local/bin/agy`), preserving subagents, background daemons, and avoiding cold-start auth latency.
- **Custom API Upstreams (Built-in Core)**: Optional built-in agent core supporting custom Anthropic / OpenAI-compatible API providers alongside `agy`.
- **Isolated Storage (`~/.ayte`)**: Completely independent bundle ID (`dev.ayte.desktop`), settings (`~/Library/Application Support/ayte`), and session transcripts (`~/.ayte/projects/`), coexisting cleanly alongside other tools.
- **Native Antigravity Customizations**: Inspect and edit global (`~/.gemini/config/`) and workspace (`.agents/`, `GEMINI.md`, `AGENTS.md`) Skills, Plugins, Rules, MCP Servers, and Hooks directly inside Settings → Customize.
- **Rich Workbench UX**: Built-in code editor & diff viewer, terminal deck, Session Replay waterfall timeline, live turn chronograph, Stash, Notch Dynamic Island & PiP watcher on macOS, and end-to-end encrypted mobile pairing.

## Building from Source

1. Make sure **Antigravity CLI (`agy`)** is installed and signed in on your machine (`agy --version`).
2. Run locally with Flutter:
   ```bash
   flutter pub get
   flutter run -d macos
   ```
3. Build release installers:
   ```bash
   dart run tool/build_macos.dart    # macOS (.dmg / .zip)
   dart run tool/build_windows.dart  # Windows (-setup.exe)
   sh tool/package_linux_deb.sh      # Linux (.deb / .tar.gz)
   ```

## Credits & License

Ayte is derived from the open-source [BaoCode](https://github.com/baocode-dev/baocode) project and distributed under the same open-source license — see [LICENSE](LICENSE) for full terms.
