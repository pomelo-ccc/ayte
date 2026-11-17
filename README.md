# Ayte

[中文说明](README_CN.md)

**Ayte** is a native desktop workbench and IDE for **Google Antigravity (`agy`)**, built with Flutter and native macOS/Windows/Linux integrations.

## Highlights

- **First-Class Antigravity CLI (`agy`) Engine**: Persistent multi-turn `stream-json` sessions over your local `agy` installation (`~/.gemini/bin/agy` or `~/.local/bin/agy`), preserving subagents, background daemons, and avoiding cold-start auth latency.
- **Custom API Upstreams (Built-in Core)**: Optional built-in agent core supporting custom Anthropic / OpenAI-compatible API providers alongside `agy`.
- **Isolated Storage (`~/.ayte`)**: Completely independent bundle ID (`dev.ayte.desktop`), settings (`~/Library/Application Support/ayte`), and session transcripts (`~/.ayte/projects/`), coexisting cleanly alongside other tools.
- **Native Antigravity Customizations**: Inspect and edit global (`~/.gemini/config/`) and workspace (`.agents/`, `GEMINI.md`, `AGENTS.md`) Skills, Plugins, Rules, MCP Servers, and Hooks directly inside Settings → Customize.
- **Rich Workbench UX**: Built-in code editor & diff viewer, terminal deck, Session Replay waterfall timeline, live turn chronograph, Stash, Notch Dynamic Island & PiP watcher on macOS, and end-to-end encrypted mobile pairing.

## Getting Started

1. Make sure **Antigravity CLI (`agy`)** is installed and signed in on your machine (`agy --version`).
2. Run locally with Flutter:
   ```bash
   flutter pub get
   flutter run -d macos
   ```
3. Build release app bundle:
   ```bash
   flutter build macos --release
   ```

## Credits & License

Ayte is derived from the open-source [BaoCode](https://github.com/baocode-dev/baocode) project and distributed under the same open-source license — see [LICENSE](LICENSE) for full terms.
