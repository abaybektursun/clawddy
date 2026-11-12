<p align="center">
  <img src="docs/images/clawddy_ascii.gif" alt="Clawddy" width="200">
</p>

<p align="center">
  Multi-agent terminal workspace built on <a href="https://github.com/ghostty-org/ghostty">Ghostty</a>.
  <br />
  Manage, monitor, and switch between Claude Code and Codex agents from a native macOS interface.
</p>

## About

Clawddy is a fork of [Ghostty](https://github.com/ghostty-org/ghostty) that adds a built-in workspace for managing multiple coding-agent terminal sessions. Each agent can use Claude Code or Codex while retaining Ghostty's speed, native feel, and rendering quality.

**What it does:**

- Organize agents into **projects** and **tasks** in a native three-column workspace
- Each agent chooses Claude Code or Codex and runs its real interactive TUI in
  a dedicated terminal surface, with provider-safe resume and fork
- Model, configured reasoning effort, permissions, and provider-supported
  telemetry are available through an accessible detail inspector
- **Option+Space** opens a Spotlight-style search to jump between agents
- Selecting an agent previews it; explicit Start/Focus actions preserve keyboard intent
- Menu bar icon shows aggregate state (idle / running / needs attention)
- Lossless ordered lifecycle-event ingestion with bounded tail reads and compaction
- Targeted macOS notifications that reopen the exact agent
- System-standard workspace chrome with the terminal retaining its configured theme
- Agents drop to a shell when their provider exits so you never lose a terminal

## Architecture

Clawddy's agent features live in `macos/Sources/Features/AgentManagement/` with
integration points in `AppDelegate.swift` and the shared command palette. The
`upstream` branch tracks `ghostty-org/ghostty` main for clean merges.

```
macos/Sources/Features/AgentManagement/
  AgentConfig.swift                — Config persistence and provider identity
  AgentPreferences.swift           — Provider default start modes and atomic persistence
  AgentProvider.swift              — Provider table, health, and launch types
  ClaudeCodeProvider.swift         — Claude Code launch, hooks, auth, and event table
  CodexProvider.swift              — Codex launch, hooks, auth, and event table
  AgentHookRuntime.swift           — Minimal provider-tagged lifecycle journal hook
  AgentSessionStore.swift          — Provider-tagged resume and fork identity
  AgentEnvironmentResolver.swift   — Nonblocking login-shell PATH discovery
  AgentEventJournal.swift          — Complete-record parsing and persisted offsets
  AgentMetadataRuntime.swift       — Claude status-line capture and forwarding
  AgentSessionMetadata.swift       — Official metadata decoding and formatting
  AgentMetadataViews.swift         — List, header, and inspector metadata UI
  AgentStateReducer.swift          — Deterministic runtime state transitions and effects
  AgentTerminalBridge.swift        — Agent lifecycle, event ingestion, and notifications
  AgentTerminalHost.swift          — Terminal model/delegate adapter for each agent
  AgentDetailViewController.swift  — Terminal-surface ownership and switching
  AgentWorkspaceViews.swift        — Navigation, agent list, search, and editing
  AgentCommandPaletteView.swift    — Agent entries for the shared command palette
  AgentSearchPanel.swift           — Floating command-palette panel
  AgentWorkspaceController.swift   — Split-view workspace and window creation
```

Read [Clawddy Agent Architecture](docs/CLAWDDY_ARCHITECTURE.md) for component
ownership and state invariants. Read
[macOS Development](docs/MACOS_DEVELOPMENT.md) before changing Apple-framework
integration, permissions, accessibility, rendering, or build settings.

## Setup

### Prerequisites

- macOS 15.6 or newer for the Xcode 26 development toolchain
- Xcode 26 with the macOS 26 SDK and Metal Toolchain
- [Zig 0.17.0](https://ziglang.org/download/)

The built application itself has a macOS 14 deployment target.

### Build

```sh
macos/build.nu --scheme Ghostty --configuration ReleaseLocal --action build
open /Volumes/Xcode/GhosttyBuilds/ghostty/macos/products/ReleaseLocal/Ghostty.app
```

When shared Zig code outside `macos/` changes, run
`./build.nu -Demit-macos-app=false` before the macOS build. See
[Developing Ghostty](HACKING.md) for tests, linting, and toolchain setup.

### Agent config

Agents are defined in `~/.config/ghostty-agents/agents.json`:

```json
{
  "schemaVersion": 5,
  "projects": [
    {
      "id": "B150F75F-55CD-44BE-8994-3B8A840D71B5",
      "name": "myproject",
      "workingDirectory": "/path/to/project",
      "tasks": [
        {
          "id": "2FCF5403-85C9-4B95-85A9-9978FB1C2F02",
          "name": "feature",
          "agents": [
            {
              "id": "534A7DB8-4623-4C40-A3C6-DF5914D1302B",
              "name": "agent-1",
              "provider": "codex",
              "launchProfile": {
                "modelID": null,
                "reasoningEffort": "high",
                "startMode": "unrestricted"
              }
            }
          ]
        }
      ]
    }
  ]
}
```

IDs and providers are stable identities; names may change. Hooks are
installed lazily for the selected provider without replacing unrelated user
hooks. Codex requires the user to review a newly installed command hook with
`/hooks` before Codex will run it.

Clawddy → Settings configures the default start mode for newly created agents.
The product defaults are **Dangerously Skip Permissions** for Claude Code and
**YOLO** for Codex; choose **Standard Permissions** to retain the provider's
normal approval and sandbox behavior.

## Syncing with upstream Ghostty

```sh
git fetch origin main
git checkout upstream
git merge origin/main
git checkout main
git merge upstream
```

## Credits

Built on [Ghostty](https://github.com/ghostty-org/ghostty) by Mitchell Hashimoto and contributors.
