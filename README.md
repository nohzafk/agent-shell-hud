# Agent Shell HUD (Workspace HUD Extension)

A highly polished, premium integration bridge that streams real-time status metrics from **[agent-shell](https://github.com/xenodium/agent-shell)** buffers directly into the floating **[emacs-workspace-hud](file:///Users/randall/projects/emacs-workspace-hud)** dashboard.

---

## 💡 How It Works

Once active, the package establishes lightweight event subscriptions on `agent-shell` comint buffers using ACP (Agent Client Protocol) event hooks. It automatically formats and pushes an **Agent** section into the Workspace HUD card:

- **State Syncing**: Shows active agent config names (e.g. `Claude Code`) and live turn status (`busy`, `ok`, `warn`, `error`).
- **Real-Time Actions**: Displays glanceable summaries of in-progress activity (e.g., `Calling fs/write_text_file` or `Wrote buffer.el`).
- **Files Touched**: Accumulates and renders counts of files touched during the active turn.
- **Context Usage**: Dynamically extracts token context consumption (e.g., `42% used`) on turn completion.

---

## 📦 Installation & Setup

Load both dependencies and this adapter package in your Emacs configuration:

```elisp
;; Add packages to load-path
(add-to-list 'load-path "/path/to/emacs-workspace-hud/lisp")
(add-to-list 'load-path "/path/to/agent-shell")
(add-to-list 'load-path "/path/to/agent-shell-hud")

(require 'workspace-hud)
(require 'agent-shell)
(require 'agent-shell-hud)

;; Enable global minor mode
(agent-shell-hud-mode 1)
```

---

## 🛠️ Verification & Building

Project builds and compiles cleanly through `just`:

```sh
just compile  # Byte-compiles the Elisp source to check for warnings
just clean    # Cleans up byte-compilation artifacts
```
