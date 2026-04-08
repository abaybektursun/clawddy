<h1>
<p align="center">
  <br>Clawddy
</h1>
  <p align="center">
    Multi-agent terminal workspace built on <a href="https://github.com/ghostty-org/ghostty">Ghostty</a>.
    <br />
    Manage, monitor, and switch between Claude Code agents from a native macOS interface.
  </p>
</p>

## About

Clawddy is a fork of [Ghostty](https://github.com/ghostty-org/ghostty) that adds a built-in agent workspace for managing multiple Claude Code terminal sessions. It inherits Ghostty's speed, native feel, and rendering quality while adding project/task/agent organization on top.

**What it does:**

- Organize agents into **projects** and **tasks** via a sidebar
- Each agent runs Claude Code in its own terminal surface with session resume
- **Option+Space** opens a Spotlight-style search to jump between agents
- Menu bar icon shows aggregate state (idle / running / needs attention)
- macOS notifications when an agent finishes or hits high context usage
- Workspace background and appearance sync with your Ghostty terminal theme
- Agents drop to a shell when Claude exits so you never lose a terminal

## Architecture

Clawddy's agent features live in `macos/Sources/Features/AgentManagement/` and a small section of `AppDelegate.swift`. The rest of the codebase is unmodified Ghostty. The `upstream` branch tracks `ghostty-org/ghostty` main for clean merges.

```
macos/Sources/Features/AgentManagement/
  AgentConfig.swift              — Project/task/agent CRUD, JSON config, Claude hooks
  AgentTerminalBridge.swift      — State polling, notifications, aggregate state
  AgentDetailViewController.swift — Terminal surface hosting with rekey support
  AgentSidebarView.swift         — Sidebar with inline rename, directory warnings
  AgentSearchView.swift          — Spotlight-style agent search
  AgentSearchPanel.swift         — Floating search panel (borderless NSPanel)
  AgentWorkspaceController.swift — NSSplitViewController layout + window creation
```

## Setup

### Prerequisites

- macOS 15+
- [Zig 0.15.2](https://ziglang.org/download/)

### Build

```sh
zig build -Doptimize=ReleaseFast
codesign --force --deep --sign - zig-out/Ghostty.app
open zig-out/Ghostty.app
```

### Agent config

Agents are defined in `~/.config/ghostty-agents/agents.json`:

```json
{
  "projects": [
    {
      "name": "myproject",
      "workingDirectory": "/path/to/project",
      "tasks": [
        {
          "name": "feature",
          "agents": ["agent-1", "agent-2"]
        }
      ]
    }
  ]
}
```

Claude Code hooks are installed automatically on first launch to track agent state (heartbeats, session IDs, context usage).

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
