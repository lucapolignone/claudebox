#!/usr/bin/env bash
# claudebox -- isolated Claude Code devcontainer for the current project folder
# macOS and Linux/Unix
#
# Uso:
#   First run (self-install):
#     bash claudebox.sh
#
#   After installation, from any folder:
#     claudebox start
#     claudebox init
#     claudebox up
#     claudebox shell
#     claudebox stop
#     claudebox destroy
#     claudebox update

set -euo pipefail

# ── Colori ─────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()   { echo -e "  ${CYAN}>${NC} $*"; }
ok()     { echo -e "  ${GREEN}OK${NC} $*"; }
warn()   { echo -e "  ${YELLOW}!!${NC} $*"; }
err()    { echo -e "  ${RED}ERR${NC} $*" >&2; exit 1; }
header() { echo -e "\n${BOLD}${BLUE}$*${NC}"; }

# ── Helpers ─────────────────────────────────────────────────────────────────────
project_name() {
    basename "$(pwd)" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]/-/g' | sed 's/-\+/-/g' | sed 's/^-//;s/-$//'
}

container_name() { echo "claudebox-$(project_name)"; }

container_exists() {
    docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$(container_name)"
}

container_running() {
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$(container_name)"
}

# ── URL base file ufficiali Anthropic ───────────────────────────────────────────
ANTHROPIC_RAW_BASE='https://raw.githubusercontent.com/anthropics/claude-code/main/.devcontainer'

# ── Download helper ─────────────────────────────────────────────────────────────
download_file() {
    local url="$1" dest="$2" label="$3"
    info "Download $label..."
    if command -v curl &>/dev/null; then
        curl -fsSL "$url" -o "$dest" || err "Failed to download $label from:\n  $url\nCheck your internet connection and try again."
    elif command -v wget &>/dev/null; then
        wget -q "$url" -O "$dest" || err "Failed to download $label from:\n  $url\nCheck your internet connection and try again."
    else
        err "curl or wget not found. Please install one and try again."
    fi
    ok "$label scaricato da GitHub ufficiale"
}

# ── AUTO-INSTALLAZIONE ──────────────────────────────────────────────────────────
cmd_install() {
    header "=== Installing claudebox ==="

    local source_script
    source_script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

    # Look for an existing install directory in user PATH
    local install_dir=""
    for candidate in "$HOME/.local/bin" "$HOME/bin"; do
        if [ -d "$candidate" ]; then
            install_dir="$candidate"
            break
        fi
    done
    # None found: create ~/.local/bin
    if [ -z "$install_dir" ]; then
        install_dir="$HOME/.local/bin"
        mkdir -p "$install_dir"
        ok "Created directory: $install_dir"
    fi

    local dest="$install_dir/claudebox"
    info "Copying script to: $dest"
    cp "$source_script" "$dest"
    chmod +x "$dest"
    ok "Script copied and made executable"

    # Add to PATH if not already there
    local shell_rc=""
    if [ -n "${ZSH_VERSION:-}" ] || [ "$(basename "${SHELL:-}")" = "zsh" ]; then
        shell_rc="$HOME/.zshrc"
    else
        shell_rc="$HOME/.bashrc"
    fi

    local path_line="export PATH=\"\$HOME/.local/bin:\$HOME/bin:\$PATH\""
    if ! grep -q 'claudebox\|\.local/bin' "$shell_rc" 2>/dev/null; then
        echo "" >> "$shell_rc"
        echo "# claudebox (added da claudebox.sh)" >> "$shell_rc"
        echo "$path_line" >> "$shell_rc"
        ok "PATH updated in: $shell_rc"
    else
        info "PATH already configured in $shell_rc"
    fi

    # Make available in current session
    export PATH="$HOME/.local/bin:$HOME/bin:$PATH"

    echo ""
    ok "Installation complete!"
    echo ""
    echo -e "  Restart the terminal (or run: source $shell_rc) to use"
    echo    "  the 'claudebox' command from any folder."
    echo ""
    echo    "  Quick start:"
    echo -e "    cd ~/projects/my-project"
    echo -e "    claudebox start"
    echo ""
}

# ── PREREQUISITI ────────────────────────────────────────────────────────────────
check_prerequisites() {
    header "=== Checking prerequisites ==="

    command -v docker &>/dev/null || err "Docker not found. Install it from https://www.docker.com/products/docker-desktop"
    ok "Docker found: $(docker --version)"

    docker info &>/dev/null || err "Docker daemon is not responding. Start Docker Desktop and try again."
    ok "Docker daemon is running"

    # CLAUDE_CONFIG_DIR
    if [ -z "${CLAUDE_CONFIG_DIR:-}" ]; then
        for candidate in "$HOME/.claude" "$HOME/.config/claude"; do
            if [ -d "$candidate" ]; then
                export CLAUDE_CONFIG_DIR="$candidate"
                warn "CLAUDE_CONFIG_DIR not set; using: $candidate"
                break
            fi
        done
        if [ -z "${CLAUDE_CONFIG_DIR:-}" ]; then
            err "CLAUDE_CONFIG_DIR not set and no Claude folder found.\nSet the variable:\n  export CLAUDE_CONFIG_DIR=~/.claude\nAdd this line to your .zshrc/.bashrc to make it permanent."
        fi
    fi
    [ -d "$CLAUDE_CONFIG_DIR" ] || err "CLAUDE_CONFIG_DIR='$CLAUDE_CONFIG_DIR' non esiste."
    ok "CLAUDE_CONFIG_DIR -> $CLAUDE_CONFIG_DIR"

    # CCSTATUSLINE_CONFIG_DIR (optional)
    if [ -z "${CCSTATUSLINE_CONFIG_DIR:-}" ]; then
        local cc_default="$HOME/.config/ccstatusline"
        if [ -d "$cc_default" ]; then
            export CCSTATUSLINE_CONFIG_DIR="$cc_default"
            warn "CCSTATUSLINE_CONFIG_DIR not set; using: $cc_default"
        else
            warn "CCSTATUSLINE_CONFIG_DIR not set and $cc_default not found. ccstatusline will not be configured."
            export CCSTATUSLINE_CONFIG_DIR="$cc_default"
        fi
    fi
    ok "CCSTATUSLINE_CONFIG_DIR -> $CCSTATUSLINE_CONFIG_DIR"
}

# ── INIT ────────────────────────────────────────────────────────────────────────
cmd_init() {
    local proj dc_dir
    proj="$(project_name)"
    dc_dir="$(pwd)/.devcontainer"

    header "=== Initializing devcontainer for '$proj' ==="

    if [ -d "$dc_dir" ]; then
        warn "Folder .devcontainer already exists."
        read -rp "Overwrite existing files? [y/N] " answer
        [ "${answer,,}" = "y" ] || { info "Cancelled."; return; }
    fi
    mkdir -p "$dc_dir"

    # Dockerfile and init-firewall.sh: downloaded from Anthropic
    info "Downloading official files from anthropics/claude-code..."
    download_file "$ANTHROPIC_RAW_BASE/Dockerfile"       "$dc_dir/Dockerfile"       "Dockerfile"
    download_file "$ANTHROPIC_RAW_BASE/init-firewall.sh" "$dc_dir/init-firewall.sh" "init-firewall.sh"
    chmod +x "$dc_dir/init-firewall.sh"

    # devcontainer.json: generated with our customizations
    info "Generating custom devcontainer.json..."
    cat > "$dc_dir/devcontainer.json" <<EOF
{
  "name": "$proj",
  "build": {
    "dockerfile": "Dockerfile"
  },
  "workspaceFolder": "/workspace",
  "workspaceMount": "source=\${localWorkspaceFolder},target=/workspace,type=bind,consistency=cached",
  "mounts": [
    "source=\${localEnv:CLAUDE_CONFIG_DIR},target=/host-claude,type=bind,readonly=true,consistency=cached",
    "source=\${localEnv:CCSTATUSLINE_CONFIG_DIR},target=/host-ccstatusline,type=bind,readonly=true,consistency=cached",
    "source=claudebox-shared-config,target=/home/node/.claude,type=volume",
    "source=claudebox-shared-ccstatusline,target=/home/node/.config/ccstatusline,type=volume",
    "source=claudebox-$proj-history,target=/commandhistory,type=volume"
  ],
  "remoteUser": "node",
  "containerEnv": {
    "CLAUDE_CONFIG_DIR": "/home/node/.claude",
    "CCSTATUSLINE_CONFIG_DIR": "/home/node/.config/ccstatusline",
    "NODE_OPTIONS": "--max-old-space-size=4096",
    "DEVCONTAINER": "true",
    "PATH": "/home/node/.local/bin:/usr/local/share/npm-global/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  },
  "runArgs": [
    "--cap-add=NET_ADMIN",
    "--cap-add=NET_RAW"
  ],
  "postStartCommand": "sudo chown -R node:node /home/node/.claude /home/node/.config && mkdir -p /home/node/.local/bin /home/node/.config/ccstatusline && if [ ! -f /home/node/.claude/.credentials.json ]; then cp -rn /host-claude/. /home/node/.claude/ 2>/dev/null || true; fi && if [ ! -f /home/node/.config/ccstatusline/settings.json ]; then cp -rn /host-ccstatusline/. /home/node/.config/ccstatusline/ 2>/dev/null || true; fi && sudo /usr/local/bin/init-firewall.sh 2>/dev/null || true",
  "customizations": {
    "vscode": {
      "extensions": [
        "anthropic.claude-code",
        "dbaeumer.vscode-eslint",
        "esbenp.prettier-vscode",
        "eamodio.gitlens"
      ],
      "settings": {
        "editor.formatOnSave": true,
        "editor.defaultFormatter": "esbenp.prettier-vscode",
        "terminal.integrated.defaultProfile.linux": "zsh"
      }
    }
  }
}
EOF

    ok "Generated .devcontainer/devcontainer.json (customized)"
    ok "Downloaded .devcontainer/Dockerfile (official Anthropic)"
    ok "Downloaded .devcontainer/init-firewall.sh (official Anthropic)"
    echo ""
    info "Next step: claudebox up"
}

# ── UP ──────────────────────────────────────────────────────────────────────────
cmd_up() {
    check_prerequisites

    [ -f ".devcontainer/devcontainer.json" ] || err "No .devcontainer found. Run first: claudebox init"

    local proj cname
    proj="$(project_name)"
    cname="$(container_name)"

    header "=== Starting devcontainer '$proj' ==="

    # Build
    info "Building Docker image (may take a few minutes on first run)..."
    docker build -t "claudebox-img-$proj" .devcontainer/
    ok "Image ready: claudebox-img-$proj"

    # Probe: verify Docker can access CLAUDE_CONFIG_DIR
    info "Verifying Docker can access CLAUDE_CONFIG_DIR..."
    if ! docker run --rm \
            -v "${CLAUDE_CONFIG_DIR}:/probe:ro" \
            "claudebox-img-$proj" \
            ls /probe &>/dev/null; then
        echo ""
        echo -e "  ${RED}ERR${NC} Docker non riesce ad accedere alla cartella:"
        echo    "      $CLAUDE_CONFIG_DIR"
        echo ""
        echo    "  On macOS: Docker Desktop -> Settings -> Resources -> File Sharing"
        echo    "  On Linux: make sure the folder exists and Docker has the right permissions"
        echo    "  Add: $CLAUDE_CONFIG_DIR"
        echo ""
        exit 1
    fi
    ok "Docker can access CLAUDE_CONFIG_DIR"

    # Probe ccstatusline dir (non-blocking)
    if [ -d "${CCSTATUSLINE_CONFIG_DIR:-}" ]; then
        if ! docker run --rm \
                -v "${CCSTATUSLINE_CONFIG_DIR}:/probe-cs:ro" \
                "claudebox-img-$proj" \
                ls /probe-cs &>/dev/null; then
            warn "Docker cannot access CCSTATUSLINE_CONFIG_DIR ($CCSTATUSLINE_CONFIG_DIR)."
            warn "ccstatusline will proceed without custom config."
        else
            ok "Docker can access CCSTATUSLINE_CONFIG_DIR"
        fi
    fi

    # Remove previous container
    if container_exists; then
        info "Removing previous container '$cname'..."
        docker rm -f "$cname" >/dev/null
    fi

    # Start container
    info "Starting container '$cname'..."
    docker run -d \
        --name "$cname" \
        --cap-add=NET_ADMIN \
        --cap-add=NET_RAW \
        -v "$(pwd):/workspace:cached" \
        -v "${CLAUDE_CONFIG_DIR}:/host-claude:ro" \
        -v "${CCSTATUSLINE_CONFIG_DIR:-/dev/null}:/host-ccstatusline:ro" \
        -v "claudebox-shared-config:/home/node/.claude" \
        -v "claudebox-shared-ccstatusline:/home/node/.config/ccstatusline" \
        -v "claudebox-${proj}-history:/commandhistory" \
        -e CLAUDE_CONFIG_DIR="/home/node/.claude" \
        -e CCSTATUSLINE_CONFIG_DIR="/home/node/.config/ccstatusline" \
        -w /workspace \
        "claudebox-img-$proj" \
        sleep infinity >/dev/null
    ok "Container started"

    # Firewall
    info "Initializing firewall..."
    if docker exec "$cname" sudo /usr/local/bin/init-firewall.sh &>/dev/null; then
        ok "Firewall applied"
    else
        warn "Firewall not applied (NET_ADMIN may not be available)."
    fi

    # Copy config on first start
    docker exec "$cname" bash -c \
        'sudo chown -R node:node /home/node/.claude /home/node/.config 2>/dev/null || true' >/dev/null
    docker exec "$cname" bash -c \
        'mkdir -p /home/node/.local/bin /home/node/.config/ccstatusline' >/dev/null
    docker exec "$cname" bash -c \
        'if [ ! -f /home/node/.claude/.credentials.json ]; then cp -rn /host-claude/. /home/node/.claude/ 2>/dev/null || true; fi' >/dev/null
    docker exec -u root "$cname" chown -R node:node /home/node/.config/ccstatusline >/dev/null
    docker exec "$cname" bash -c \
        'if [ ! -f /home/node/.config/ccstatusline/settings.json ]; then cp -rn /host-ccstatusline/. /home/node/.config/ccstatusline/ 2>/dev/null || true; fi' >/dev/null

    # Fix Windows paths in JSON config files (no-op on macOS/Linux, but run for safety)
    docker exec -u node "$cname" node -e '
const fs = require("fs");
const path = require("path");
const CLAUDE_DIR = "/home/node/.claude";
const TARGET_DIRS = ["plugins", "ide", "config"];
const WIN_PATH_RE = /[A-Za-z]:[\\\/][^"\n]*/g;
function fixValue(str) {
  return str.replace(WIN_PATH_RE, match => {
    let p = match.replace(/\\/g, "/");
    p = p.replace(/^[A-Za-z]:\/.*?\.claude/, CLAUDE_DIR);
    return p;
  });
}
function fixJsonFile(filePath) {
  try {
    const raw = fs.readFileSync(filePath, "utf8");
    WIN_PATH_RE.lastIndex = 0;
    if (!WIN_PATH_RE.test(raw)) return;
    WIN_PATH_RE.lastIndex = 0;
    const fixed = fixValue(raw);
    if (fixed !== raw) fs.writeFileSync(filePath, fixed, "utf8");
  } catch (e) {}
}
function walk(dir) {
  let entries;
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch (e) { return; }
  for (const entry of entries) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) walk(full);
    else if (entry.isFile() && entry.name.endsWith(".json")) fixJsonFile(full);
  }
}
for (const dir of TARGET_DIRS) walk(path.join(CLAUDE_DIR, dir));
' 2>/dev/null || true

    # Verify isolation
    header "=== Container isolation check ==="
    local workdir
    workdir=$(docker exec -u node "$cname" pwd)
    if [ "${workdir}" = "/workspace" ]; then
        ok "Isolation confirmed: pwd = /workspace"
    else
        err "Isolation NOT verified: pwd = '$workdir' (expected /workspace)"
    fi

    # Launch Claude Code
    header "=== Launching Claude Code (--dangerously-skip-permissions) ==="
    echo -e "  ${YELLOW}Il container e pronto. Lancio Claude Code...${NC}"
    echo -e "  ${YELLOW}Digita 'exit' per uscire dalla shell del container.${NC}\n"
    docker exec -it -u node "$cname" \
        zsh -c 'claude --dangerously-skip-permissions; exec zsh'
}

# ── UPDATE ──────────────────────────────────────────────────────────────────────
cmd_update() {
    local dc_dir
    dc_dir="$(pwd)/.devcontainer"

    header "=== Updating official Anthropic files ==="

    [ -d "$dc_dir" ] || err "No .devcontainer found. Run first: claudebox init"

    info "Downloading updated files from anthropics/claude-code (main)..."
    download_file "$ANTHROPIC_RAW_BASE/Dockerfile"       "$dc_dir/Dockerfile"       "Dockerfile"
    download_file "$ANTHROPIC_RAW_BASE/init-firewall.sh" "$dc_dir/init-firewall.sh" "init-firewall.sh"
    chmod +x "$dc_dir/init-firewall.sh"

    echo ""
    ok "Official files updated. devcontainer.json unchanged."
    info "Run 'claudebox up' to rebuild the image with the updates."
}

# ── START ───────────────────────────────────────────────────────────────────────
cmd_start() {
    local proj dc_dir
    proj="$(project_name)"
    dc_dir="$(pwd)/.devcontainer"

    # Banner
    echo ""
    echo -e "  ${BLUE}+======================================================+${NC}"
    echo -e "  ${BLUE}|         claudebox  --  automated setup             |${NC}"
    echo -e "  ${BLUE}+======================================================+${NC}"
    echo ""
    echo -e "  Progetto : ${BOLD}$proj${NC}"
    echo    "  Folder   : $(pwd)"

    # Resolve CLAUDE_CONFIG_DIR
    if [ -z "${CLAUDE_CONFIG_DIR:-}" ]; then
        for candidate in "$HOME/.claude" "$HOME/.config/claude"; do
            if [ -d "$candidate" ]; then
                export CLAUDE_CONFIG_DIR="$candidate"
                break
            fi
        done
    fi

    # If still not found, ask
    if [ -z "${CLAUDE_CONFIG_DIR:-}" ] || [ ! -d "${CLAUDE_CONFIG_DIR}" ]; then
        echo ""
        warn "CLAUDE_CONFIG_DIR not set or not found automatically."
        echo ""
        echo "  Claude Code stores credentials and settings in a dedicated folder."
        echo "  Usually located at: $HOME/.claude"
        echo ""
        read -rp "  Enter Claude config path [default: $HOME/.claude]: " input_dir
        input_dir="${input_dir:-$HOME/.claude}"
        if [ ! -d "$input_dir" ]; then
            warn "Folder '$input_dir' does not exist. Creating it now."
            mkdir -p "$input_dir"
        fi
        export CLAUDE_CONFIG_DIR="$input_dir"
        # Save permanently
        local shell_rc
        if [ "$(basename "${SHELL:-}")" = "zsh" ]; then shell_rc="$HOME/.zshrc"; else shell_rc="$HOME/.bashrc"; fi
        echo "" >> "$shell_rc"
        echo "export CLAUDE_CONFIG_DIR=\"$input_dir\"" >> "$shell_rc"
        ok "CLAUDE_CONFIG_DIR set permanently in $shell_rc"
    fi

    # Resolve CCSTATUSLINE_CONFIG_DIR
    if [ -z "${CCSTATUSLINE_CONFIG_DIR:-}" ]; then
        local cc_default="$HOME/.config/ccstatusline"
        [ -d "$cc_default" ] && export CCSTATUSLINE_CONFIG_DIR="$cc_default"
    fi

    echo    "  Config   : $CLAUDE_CONFIG_DIR"
    echo -n "  ccstatus : "
    if [ -n "${CCSTATUSLINE_CONFIG_DIR:-}" ] && [ -d "${CCSTATUSLINE_CONFIG_DIR}" ]; then
        echo "$CCSTATUSLINE_CONFIG_DIR"
    else
        echo "(not found, will be skipped)"
    fi

    local has_devcontainer=false do_update=false
    [ -f "$dc_dir/devcontainer.json" ] && has_devcontainer=true

    # Ask about update if .devcontainer already exists
    if $has_devcontainer; then
        echo ""
        echo "  +- Dockerfile and init-firewall.sh may be outdated."
        echo "  |  Update official Anthropic files before starting?"
        read -rp "  +- Update? [y/N] " update_answer
        [ "${update_answer,,}" = "y" ] && do_update=true
    fi

    # Current state
    echo ""
    echo "  Current state:"
    echo -n "    .devcontainer : "
    $has_devcontainer && echo "present" || echo "missing  -> will be created"
    echo -n "    Container     : "
    if container_running; then echo "running  -> will be recreated"
    elif container_exists; then echo "stopped  -> will be recreated"
    else echo "missing  -> will be created"; fi

    # Step summary
    local step=1
    echo ""
    echo "  Steps to be executed:"
    if ! $has_devcontainer; then
        echo "    $step. init   -- download official Anthropic files and generate devcontainer.json"; ((step++))
    elif $do_update; then
        echo "    $step. update -- re-download Dockerfile and init-firewall.sh from Anthropic"; ((step++))
    fi
    echo "    $step. build  -- build the Docker image"; ((step++))
    echo "    $step. run    -- start container and mount directories"; ((step++))
    echo "    $step. check  -- verify isolation (pwd = /workspace)"; ((step++))
    echo "    $step. claude -- launch claude --dangerously-skip-permissions"
    echo ""

    read -rp "  Start? [Y/n] " confirm
    [ "${confirm,,}" = "n" ] && { info "Cancelled."; return; }

    if ! $has_devcontainer; then
        echo ""
        header "=== Init devcontainer ==="
        cmd_init
    elif $do_update; then
        echo ""
        header "=== Update file ufficiali Anthropic ==="
        cmd_update
    else
        echo ""
        ok "Using existing configuration in .devcontainer/ (no update requested)"
    fi

    echo ""
    cmd_up
}

# ── SHELL ───────────────────────────────────────────────────────────────────────
cmd_shell() {
    local cname
    cname="$(container_name)"
    container_running || err "Container '$cname' is not running. Use: claudebox up"
    info "Opening shell in '$cname'..."
    docker exec -it -u node "$cname" zsh
}

# ── STOP ────────────────────────────────────────────────────────────────────────
cmd_stop() {
    local cname
    cname="$(container_name)"
    container_running || { info "Container is not running."; return; }
    docker stop "$cname" >/dev/null
    ok "Container '$cname' stopped."
}

# ── DESTROY ─────────────────────────────────────────────────────────────────────
cmd_destroy() {
    local proj cname
    proj="$(project_name)"
    cname="$(container_name)"

    warn "This will remove the container, history volume and image for '$proj'."
    echo  "  Shared volume 'claudebox-shared-config' is NOT removed (shared across projects)."
    read -rp "Continue? [y/N] " answer
    [ "${answer,,}" = "y" ] || { info "Cancelled."; return; }

    container_exists && { docker rm -f "$cname" >/dev/null; ok "Container rimosso"; }
    docker volume rm "claudebox-${proj}-history" 2>/dev/null && ok "Volume history rimosso" || true
    docker rmi "claudebox-img-$proj" 2>/dev/null && ok "Image removed" || true

    echo ""
    echo "  To also remove shared config volumes:"
    echo "    docker volume rm claudebox-shared-config claudebox-shared-ccstatusline"
}

# ── HELP ────────────────────────────────────────────────────────────────────────
cmd_help() {
    cat <<HELP

  claudebox -- isolated Claude Code devcontainer for the current project folder

  USAGE
    claudebox <command>

  COMMANDS
    install   Self-install: copy script to ~/.local/bin
    start     Full auto-setup: init (if needed) + build + run + claude
    init      Download Dockerfile and init-firewall.sh from Anthropic, generate devcontainer.json
    update    Re-download Dockerfile and init-firewall.sh from Anthropic (devcontainer.json unchanged)
    up        Build image, start container, verify isolation, launch claude
    shell     Open a shell in the running container
    stop      Stop the container (without removing it)
    destroy   Remove container, history volume and image

  ENVIRONMENT VARIABLES
    CLAUDE_CONFIG_DIR         Claude Code config directory (default: ~/.claude)
    CCSTATUSLINE_CONFIG_DIR   ccstatusline config directory (default: ~/.config/ccstatusline)

  FIRST RUN
    # Download and install (one-time):
    bash claudebox.sh

    # Then from any project folder -- all in one command:
    cd ~/projects/my-project
    claudebox start

    # Or step by step:
    claudebox init
    claudebox up

HELP
}

# ── ENTRY POINT ─────────────────────────────────────────────────────────────────
case "${1:-install}" in
    install) cmd_install ;;
    init)    cmd_init    ;;
    up)      cmd_up      ;;
    start)   cmd_start   ;;
    update)  cmd_update  ;;
    shell)   cmd_shell   ;;
    stop)    cmd_stop    ;;
    destroy) cmd_destroy ;;
    help|--help|-h) cmd_help ;;
    *) cmd_help ;;
esac
