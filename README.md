# claudebox

Zero-dependency CLI to spin up an isolated Claude Code devcontainer in any project folder. Windows, macOS and Linux.

claudebox downloads the official Anthropic `Dockerfile` and `init-firewall.sh` directly from [`anthropics/claude-code`](https://github.com/anthropics/claude-code), generates a project-specific `devcontainer.json`, mounts your existing Claude Code credentials from the host (read-only), and launches the container with `claude --dangerously-skip-permissions` after verifying isolation is correct.

---

## Requirements

- **Docker Desktop** (Windows, macOS) or **Docker Engine** (Linux), running
- **Claude Code** installed and authenticated on the host (credentials in `~/.claude`)
- **PowerShell 5.1+** (Windows) or **bash/zsh** (macOS, Linux)

---

## Installation

### Windows (PowerShell)

Download `claudebox.ps1`, then run:

```powershell
# Allow script execution (one-time)
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser

# Unblock the downloaded file
Unblock-File .\claudebox.ps1

# Self-install: copies the script to ~/.local/bin and adds the alias to your profile
.\claudebox.ps1
```

Restart PowerShell (or run `. $PROFILE`) — the `claudebox` command is now available everywhere.

### macOS / Linux

Download `claudebox.sh`, then run:

```bash
bash claudebox.sh
```

The script copies itself to `~/.local/bin/claudebox` and adds it to your PATH via `.zshrc` or `.bashrc`.

Restart the terminal (or run `source ~/.zshrc`) — the `claudebox` command is now available everywhere.

---

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `CLAUDE_CONFIG_DIR` | `~/.claude` | Claude Code config and credentials directory on the host |
| `CCSTATUSLINE_CONFIG_DIR` | `~/.config/ccstatusline` | [ccstatusline](https://github.com/sirmalloc/ccstatusline) config directory (optional) |

Both are auto-detected if not set. To set them permanently:

**Windows:**
```powershell
[Environment]::SetEnvironmentVariable('CLAUDE_CONFIG_DIR', "$env:USERPROFILE\.claude", 'User')
```

**macOS / Linux:**
```bash
echo 'export CLAUDE_CONFIG_DIR="$HOME/.claude"' >> ~/.zshrc
```

### Docker Desktop — File Sharing (Windows and macOS)

Docker needs access to your Claude Code config directory. If `claudebox up` reports an access error:

1. Open **Docker Desktop → Settings → Resources → File Sharing**
2. Add the path of `CLAUDE_CONFIG_DIR` (e.g. `C:\Users\you\.claude`)
3. If you use ccstatusline, also add `CCSTATUSLINE_CONFIG_DIR`
4. Click **Apply & Restart**

On Linux this step is not required.

---

## Usage

### Quickstart

```bash
cd /path/to/your/project
claudebox start
```

`start` shows an interactive summary, optionally updates the official Anthropic files if `.devcontainer/` already exists, then runs `init` → `build` → `run` → isolation check → `claude --dangerously-skip-permissions` in sequence.

### Commands

| Command | Description |
|---|---|
| `claudebox start` | Full auto-setup: init (if needed) + build + run + claude |
| `claudebox init` | Download `Dockerfile` and `init-firewall.sh` from Anthropic, generate `devcontainer.json` |
| `claudebox up` | Build image, start container, verify isolation, launch claude |
| `claudebox update` | Re-download `Dockerfile` and `init-firewall.sh` from Anthropic (keeps `devcontainer.json` untouched) |
| `claudebox shell` | Open a zsh shell in the running container |
| `claudebox stop` | Stop the container (without removing it) |
| `claudebox destroy` | Remove the container, history volume and image for the current project |

### Skip confirmations (`-y`)

All commands that ask for confirmation support the `-y` flag (or `--yes` on macOS/Linux), which automatically answers yes to every prompt and uses defaults for any input:

```powershell
# Windows
claudebox start -y       # no prompts at all
claudebox destroy -y
claudebox init -y
```

```bash
# macOS / Linux
claudebox start -y
claudebox start --yes
```

When `-y` is active the update prompt in `start` defaults to **no update** (safe default — update explicitly with `claudebox update` if needed).

### Typical workflow

```bash
# First time on a project
cd ~/projects/my-project
claudebox start -y       # generates everything and opens claude, no questions asked

# Subsequent runs
claudebox start          # asks whether to update, then starts
claudebox start -y       # skips all prompts, goes straight to build + run
# or, to re-attach without rebuilding:
claudebox shell

# Update Anthropic files without recreating everything
claudebox update
claudebox up

# Full cleanup for this project
claudebox destroy -y
```

---

## Mount architecture

```
Host                                     Container
──────────────────────────────────────────────────────────────────────
CLAUDE_CONFIG_DIR            ->  /host-claude              (read-only)
CCSTATUSLINE_CONFIG_DIR      ->  /host-ccstatusline        (read-only)

                                on first start: cp -rn
                                       |
                                       v
volume claudebox-shared-config        ->  /home/node/.claude
volume claudebox-shared-ccstatusline  ->  /home/node/.config/ccstatusline
volume claudebox-<project>-history    ->  /commandhistory
current project directory             ->  /workspace         (read-write)
```

**Why this design:**

- `CLAUDE_CONFIG_DIR` is mounted **read-only** at `/host-claude` — the host is never modified by the container
- Claude Code works on a **Docker volume** (`claudebox-shared-config`) backed by a native Linux filesystem — no issues with atomic rename operations on NTFS/Windows
- Credentials are copied from the host to the volume **only on first start** (when `.credentials.json` is not yet in the volume)
- `claudebox-shared-config` is **shared across all devcontainers** — same credentials and settings for every project
- The history volume is **per-project** — shell history does not bleed between projects
- Code changes in `/workspace` are immediately visible in your IDE on the host

---

## Generated `.devcontainer/` files

| File | Source | Notes |
|---|---|---|
| `Dockerfile` | Downloaded from `anthropics/claude-code` | Official Anthropic image |
| `init-firewall.sh` | Downloaded from `anthropics/claude-code` | Official Anthropic firewall script |
| `devcontainer.json` | Generated by claudebox | Project name + config mount customizations |

`claudebox update` refreshes only `Dockerfile` and `init-firewall.sh`, leaving `devcontainer.json` untouched.

You can commit `.devcontainer/` to your repository to share the setup with your team — each developer only needs their own `CLAUDE_CONFIG_DIR` with valid credentials.

---

## Shared Docker volumes

| Volume | Mount in container | Contents |
|---|---|---|
| `claudebox-shared-config` | `/home/node/.claude` | Claude Code credentials and settings |
| `claudebox-shared-ccstatusline` | `/home/node/.config/ccstatusline` | ccstatusline configuration |
| `claudebox-<project>-history` | `/commandhistory` | Per-project shell history |

To reset shared config (e.g. after updating credentials on the host):

```bash
docker volume rm claudebox-shared-config claudebox-shared-ccstatusline
```

The next `claudebox up` will recreate the volumes and copy the config from the host.

---

## Security

- Claude Code runs with `--dangerously-skip-permissions` because the container itself is the sandbox
- The host filesystem is inaccessible except for `/workspace` (the current project) and the read-only config mounts
- The `init-firewall.sh` script (official Anthropic) restricts outbound network traffic to: Anthropic API, npm registry, GitHub, statsig, sentry
- On Windows/macOS the firewall may not activate (`NET_ADMIN` unavailable) — filesystem isolation still applies
- Claude credentials are never written into the Docker image

---

## Compatibility

| Platform | Script | Notes |
|---|---|---|
| Windows 10/11 | `claudebox.ps1` | Requires Docker Desktop and PowerShell 5.1+ |
| macOS | `claudebox.sh` | Requires Docker Desktop |
| Linux | `claudebox.sh` | Requires Docker Engine; no File Sharing configuration needed |
