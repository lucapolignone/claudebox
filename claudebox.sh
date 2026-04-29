#!/usr/bin/env bash
# claudebox -- isolated Claude Code devcontainer for the current project folder
# macOS and Linux/Unix
#
# Uso:
#   First run (self-install):
#     bash claudebox.sh install
#
#   After installation, from any folder:
#     claudebox start
#     claudebox start -y     # skip all confirmations
#     claudebox init
#     claudebox up
#     claudebox shell
#     claudebox stop
#     claudebox destroy
#     claudebox update

set -euo pipefail

# -y / --yes flag: skip all confirmation prompts
# --no-update / -n flag: skip automatic Claude Code update on container start
# --use-rtk flag: opt-in to rtk install/update on container start (off by default)
AUTO_YES=false
NO_UPDATE=false
USE_RTK=false
PROFILE='personal'
for arg in "$@"; do
    case "$arg" in
        -y|--yes) AUTO_YES=true ;;
        -n|--no-update) NO_UPDATE=true ;;
        --use-rtk) USE_RTK=true ;;
        -p|--profile) : ;; # handled below with shift
    esac
done
# Parse -p/--profile value
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
    if [[ "${args[$i]}" == '-p' || "${args[$i]}" == '--profile' ]]; then
        PROFILE="${args[$((i+1))]:-personal}"
    fi
done

confirm_step() {
    local prompt="$1"
    $AUTO_YES && return 0
    read -rp "$prompt" _r
    # FIX: ${var,,} richiede bash 4+. macOS di default ha bash 3.2 -> usiamo tr.
    local _r_lower
    _r_lower=$(printf '%s' "$_r" | tr '[:upper:]' '[:lower:]')
    [ "$_r_lower" != "n" ]
}

read_input_or_default() {
    local prompt="$1" default="$2"
    if $AUTO_YES; then echo "$default"; return; fi
    read -rp "$prompt" _v
    echo "${_v:-$default}"
}

# ── Profile resolution ─────────────────────────────────────────────────────────
resolve_profile() {
    local prof="${1:-personal}"
    if [ "$prof" = 'personal' ]; then echo "$HOME/.claude"
    else echo "$HOME/.claude-$prof"; fi
}
volume_suffix() {
    local prof="${1:-personal}"
    if [ "$prof" = 'personal' ]; then echo 'personal'
    else echo "$prof"; fi
}

# ── Colori ─────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()   { echo -e "  ${CYAN}>${NC} $*"; }
ok()     { echo -e "  ${GREEN}OK${NC} $*"; }
warn()   { echo -e "  ${YELLOW}!!${NC} $*"; }
err()    { echo -e "  ${RED}ERR${NC} $*" >&2; exit 1; }
header() { echo -e "\n${BOLD}${BLUE}$*${NC}"; }

# ── Helpers ─────────────────────────────────────────────────────────────────────
# FIX: realpath non esiste di default su macOS. _resolve_path e' un fallback portabile
# (coreutils -> python3 -> cd/pwd) che funziona anche quando il path non esiste.
_resolve_path() {
    local p="$1"
    if command -v realpath >/dev/null 2>&1; then
        realpath "$p" 2>/dev/null || printf '%s' "$p"
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$p" 2>/dev/null \
            || printf '%s' "$p"
    else
        local dir file
        dir="$(cd "$(dirname "$p")" 2>/dev/null && pwd -P)" || true
        file="$(basename "$p")"
        if [ -n "$dir" ]; then printf '%s/%s' "$dir" "$file"
        else printf '%s' "$p"; fi
    fi
}

project_name() {
    basename "$(pwd)" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]/-/g' | sed 's/-\+/-/g' | sed 's/^-//;s/-$//'
}

# Il nome del container include il profilo (tranne 'personal', per retrocompatibilita')
container_name() {
    local base="claudebox-$(project_name)"
    if [ "$PROFILE" != "personal" ] && [ -n "$PROFILE" ]; then
        echo "${base}-${PROFILE}"
    else
        echo "$base"
    fi
}

container_exists() {
    docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$(container_name)"
}

container_running() {
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$(container_name)"
}

# ── Version pinning ─────────────────────────────────────────────────────────────
# Rende la cache di Docker consapevole della versione di claude-code.
# Scarichiamo il Dockerfile ufficiale da Anthropic e poi sostituiamo
# `@anthropic-ai/claude-code` con `@anthropic-ai/claude-code@<latest>`:
#   - versione invariata -> file identico -> cache Docker hit -> build istantanea
#   - versione nuova      -> riga RUN diversa -> cache invalidata da quel layer
#     in poi, rebuild solo degli step che dipendono da CC (non da zero)
get_latest_cc_version() {
    local url='https://registry.npmjs.org/@anthropic-ai/claude-code/latest'
    local json=''
    if command -v curl >/dev/null 2>&1; then
        json=$(curl -fsSL --max-time 10 "$url" 2>/dev/null) || return 1
    elif command -v wget >/dev/null 2>&1; then
        json=$(wget -qO- --timeout=10 "$url" 2>/dev/null) || return 1
    else
        return 1
    fi
    # Estrai il campo "version" senza dipendere da jq/python (portabile)
    printf '%s' "$json" \
        | grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]+"' \
        | head -1 \
        | awk -F'"' '{print $(NF-1)}'
}

pin_dockerfile_cc_version() {
    local dockerfile="$1" version="$2"
    [ -f "$dockerfile" ] || return 1
    # Il Dockerfile ufficiale Anthropic usa `@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}`.
    # La char class deve accettare $, {, } (interpolazione ARG/ENV) altrimenti
    # lasciamo la riga rotta: "@2.1.112@${CLAUDE_CODE_VERSION}" -> npm error EINVALIDTAGNAME.
    # Escludiamo solo whitespace e shell operators come terminatori del pin.
    # Delimitatore sed: # (evita conflitto con | dentro la char class).
    local tmp; tmp=$(mktemp)
    sed -E "s#@anthropic-ai/claude-code(@[^[:space:];&|]*)?#@anthropic-ai/claude-code@${version}#g" \
        "$dockerfile" > "$tmp" && mv "$tmp" "$dockerfile"
    return 0
}

# ── rtk integration ────────────────────────────────────────────────────────────
# rtk (https://github.com/rtk-ai/rtk) e' un proxy CLI in Rust che riduce il
# consumo di token degli LLM filtrando l'output di comandi comuni (git, ls, cat,
# grep, test runner, ...). E' un binario singolo statico, distribuito come
# release pre-compilate su GitHub.
#
# Strategia di integrazione (specchio di quella di Claude Code):
#   1) Recuperiamo la versione "latest" da GitHub Releases
#   2) Iniettiamo nel Dockerfile (scaricato da Anthropic) un blocco delimitato
#      da marker, idempotente: se la versione non cambia il file resta
#      identico -> cache Docker hit; se cambia, solo gli ultimi layer si
#      ricompilano (download + install rtk)
#   3) L'architettura viene detectata in fase di RUN con `uname -m`, cosi' lo
#      stesso Dockerfile funziona su host x86_64 (Intel) e aarch64 (Apple Silicon)
#   4) Dopo lo start del container, registriamo l'hook PreToolUse in
#      ~/.claude/settings.json con `rtk init -g --auto-patch` (idempotente)
#
# Marker univoci: usiamo stringhe lunghe e specifiche per evitare di matchare
# accidentalmente commenti del Dockerfile ufficiale.
RTK_MARKER_OPEN='# >>> claudebox: rtk-install (managed) <<<'
RTK_MARKER_CLOSE='# <<< claudebox: rtk-install (managed) >>>'

get_latest_rtk_version() {
    # Endpoint pubblico, no auth. Limit GitHub: 60 req/h per IP non autenticato,
    # ampiamente sufficiente per uno script CLI.
    local url='https://api.github.com/repos/rtk-ai/rtk/releases/latest'
    local json=''
    if command -v curl >/dev/null 2>&1; then
        json=$(curl -fsSL --max-time 10 \
            -H 'Accept: application/vnd.github+json' \
            "$url" 2>/dev/null) || return 1
    elif command -v wget >/dev/null 2>&1; then
        json=$(wget -qO- --timeout=10 \
            --header='Accept: application/vnd.github+json' \
            "$url" 2>/dev/null) || return 1
    else
        return 1
    fi
    # Estrai "tag_name": "vX.Y.Z" e strippa la "v" iniziale
    printf '%s' "$json" \
        | grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"' \
        | head -1 \
        | awk -F'"' '{print $(NF-1)}' \
        | sed 's/^v//'
}

# Rimuove il blocco rtk dal Dockerfile (se presente). Usato sia per pulire prima
# di reinserire il blocco aggiornato (con --use-rtk), sia come comportamento di
# default (rtk off) per garantire che il Dockerfile resti pulito.
remove_dockerfile_rtk_block() {
    local dockerfile="$1"
    [ -f "$dockerfile" ] || return 0
    # Due pass:
    #  1) awk: salta tutte le righe da OPEN a CLOSE (inclusive)
    #  2) awk: strippa eventuali trailing blank lines del file
    # La pulizia delle blank trailing e' indispensabile per l'idempotenza:
    # senza di essa, ogni remove+append accumulerebbe una blank line in piu',
    # cambiando il contenuto del Dockerfile -> cache miss anche con stessa
    # versione di rtk.
    # NOTE: non usiamo `-v close=...` perche' `close` e' una keyword built-in di
    # gawk (chiude file/pipe) e provoca "cannot command line assign to close".
    local tmp; tmp=$(mktemp)
    awk -v mopen="$RTK_MARKER_OPEN" -v mclose="$RTK_MARKER_CLOSE" '
        $0 == mopen { skip=1; next }
        skip && $0 == mclose { skip=0; next }
        !skip { print }
    ' "$dockerfile" \
    | awk '
        /[^[:space:]]/ { last=NR }
        { lines[NR]=$0 }
        END { for (i=1; i<=last; i++) print lines[i] }
    ' > "$tmp" && mv "$tmp" "$dockerfile"
}

pin_dockerfile_rtk_version() {
    local dockerfile="$1" version="$2"
    [ -f "$dockerfile" ] || return 1

    # Step 1: rimuovi blocco esistente (idempotenza)
    remove_dockerfile_rtk_block "$dockerfile"

    # Step 2: appendi blocco aggiornato.
    # Note implementative del blocco RUN:
    #  - `USER root` ... `USER node`: il Dockerfile Anthropic termina con
    #    `USER node`; ripristiniamo l'invariante alla fine del nostro blocco.
    #  - `set -eux`: failure-fast e log delle riga eseguite (utile in build CI)
    #  - rtk pubblica due target Linux: x86_64-unknown-linux-musl (statico) e
    #    aarch64-unknown-linux-gnu (glibc, va bene su immagine Anthropic basata
    #    su Debian/Ubuntu). Gli altri arch non sono supportati: fallisce esplicito.
    #  - install -m 0755: copia atomica + permessi corretti, accessibile a node.
    #  - `rtk --version` come ultimo step e' uno smoke test: se il binario non
    #    esegue (libc mismatch, download corrotto, ...) la build fallisce subito.
    cat >> "$dockerfile" <<EOF

${RTK_MARKER_OPEN}
# rtk (https://github.com/rtk-ai/rtk) v${version} - LLM token reducer
# Managed by claudebox: do not edit this block manually. Rerun 'claudebox up'
# (with --use-rtk) to update, or omit --use-rtk to remove rtk integration.
USER root
RUN set -eux; \\
    arch="\$(uname -m)"; \\
    case "\$arch" in \\
        x86_64)  rtk_target='x86_64-unknown-linux-musl' ;; \\
        aarch64) rtk_target='aarch64-unknown-linux-gnu' ;; \\
        *) echo "rtk: unsupported architecture '\$arch'" >&2; exit 1 ;; \\
    esac; \\
    curl -fsSL "https://github.com/rtk-ai/rtk/releases/download/v${version}/rtk-\${rtk_target}.tar.gz" \\
        -o /tmp/rtk.tar.gz; \\
    tar -xzf /tmp/rtk.tar.gz -C /tmp; \\
    install -m 0755 /tmp/rtk /usr/local/bin/rtk; \\
    rm -rf /tmp/rtk /tmp/rtk.tar.gz; \\
    /usr/local/bin/rtk --version
USER node
${RTK_MARKER_CLOSE}
EOF
    return 0
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
    # FIX: usiamo _resolve_path (portabile anche su macOS senza coreutils)
    if [ "$(_resolve_path "$source_script")" = "$(_resolve_path "$dest")" ]; then
        ok "Already installed at: $dest"
    else
        info "Copying script to: $dest"
        cp "$source_script" "$dest"
        chmod +x "$dest"
        ok "Script copied and made executable"
    fi

    # Add to PATH if not already there
    local shell_rc=""
    if [ -n "${ZSH_VERSION:-}" ] || [ "$(basename "${SHELL:-}")" = "zsh" ]; then
        shell_rc="$HOME/.zshrc"
    else
        shell_rc="$HOME/.bashrc"
    fi

    local path_line="export PATH=\"\$HOME/.local/bin:\$HOME/bin:\$PATH\""
    # FIX: se shell_rc non esiste ancora (utenza nuova), lo creiamo vuoto prima
    # del grep per evitare che l'append dipenda dall'ordine di esistenza.
    [ -f "$shell_rc" ] || touch "$shell_rc"
    # FIX: 'A\|B' e' alternation GNU (BRE extended). BSD grep su macOS non lo
    # interpreta. -E attiva ERE in modo portabile su tutte le piattaforme.
    if ! grep -qE 'claudebox|\.local/bin' "$shell_rc" 2>/dev/null; then
        echo "" >> "$shell_rc"
        echo "# claudebox (added by claudebox.sh)" >> "$shell_rc"
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
    echo    "    claudebox start"
    echo    "    claudebox start -y     # skip all confirmations"
    echo ""
}

# ── PREREQUISITI ────────────────────────────────────────────────────────────────
check_prerequisites() {
    header "=== Checking prerequisites ==="

    command -v docker &>/dev/null || err "Docker not found. Install it from https://www.docker.com/products/docker-desktop"
    ok "Docker found: $(docker --version)"

    docker info &>/dev/null || err "Docker daemon is not responding. Start Docker Desktop and try again."
    ok "Docker daemon is running"

    # CLAUDE_CONFIG_DIR -- resolved from PROFILE
    local profile_dir
    profile_dir=$(resolve_profile "$PROFILE")
    if [ -n "${CLAUDE_CONFIG_DIR:-}" ] && [ "$PROFILE" = "personal" ]; then
        profile_dir="$CLAUDE_CONFIG_DIR"
    fi
    export CLAUDE_CONFIG_DIR="$profile_dir"
    if [ ! -d "$CLAUDE_CONFIG_DIR" ]; then
        warn "Profile directory does not exist. Creating: $CLAUDE_CONFIG_DIR"
        mkdir -p "$CLAUDE_CONFIG_DIR"
    fi
    ok "Profile '$PROFILE' -> $CLAUDE_CONFIG_DIR"

    # CLAUDE_PLUGINS_DIR (derived from CLAUDE_CONFIG_DIR)
    if [ -z "${CLAUDE_PLUGINS_DIR:-}" ]; then
        export CLAUDE_PLUGINS_DIR="$CLAUDE_CONFIG_DIR/plugins"
    fi
    ok "CLAUDE_PLUGINS_DIR -> $CLAUDE_PLUGINS_DIR"

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
        confirm_step "Overwrite existing files? [y/N] " || { info "Cancelled."; return; }
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
    "source=\${localEnv:CLAUDE_PLUGINS_DIR},target=/host-claude-plugins,type=bind,readonly=true,consistency=cached",
    "source=\${localEnv:CCSTATUSLINE_CONFIG_DIR},target=/host-ccstatusline,type=bind,readonly=true,consistency=cached",
    "source=claudebox-shared-config,target=/home/node/.claude,type=volume",
    "source=claudebox-shared-ccstatusline,target=/home/node/.config/ccstatusline,type=volume",
    "source=claudebox-$proj-history,target=/commandhistory,type=volume"
  ],
  "remoteUser": "node",
  "containerEnv": {
    "CLAUDE_CONFIG_DIR": "/home/node/.claude",
    "CLAUDE_PLUGINS_DIR": "/home/node/.claude/plugins",
    "CCSTATUSLINE_CONFIG_DIR": "/home/node/.config/ccstatusline",
    "NODE_OPTIONS": "--max-old-space-size=4096",
    "DEVCONTAINER": "true",
    "PATH": "/home/node/.local/bin:/usr/local/share/npm-global/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  },
  "runArgs": [
    "--cap-add=NET_ADMIN",
    "--cap-add=NET_RAW"
  ],
  "postStartCommand": "sudo chown -R node:node /home/node/.claude /home/node/.config && mkdir -p /home/node/.local/bin /home/node/.config/ccstatusline /home/node/.claude/plugins && if [ ! -f /home/node/.claude/.credentials.json ]; then cp -rn /host-claude/. /home/node/.claude/ 2>/dev/null || true; fi && cp -rn /host-claude-plugins/. /home/node/.claude/plugins/ 2>/dev/null || true && if [ ! -f /home/node/.config/ccstatusline/settings.json ]; then cp -rn /host-ccstatusline/. /home/node/.config/ccstatusline/ 2>/dev/null || true; fi && sudo /usr/local/bin/init-firewall.sh 2>/dev/null || true",
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

    # Pin versione Claude Code nel Dockerfile (prima della build)
    # Forza l'invalidazione della cache Docker solo quando c'e' effettivamente
    # una versione nuova. Se la versione e' la stessa, il file non cambia e
    # la cache viene riutilizzata.
    if [ "$NO_UPDATE" != "true" ]; then
        info "Checking latest Claude Code version on npm..."
        latest_ver=$(get_latest_cc_version || true)
        if [ -n "$latest_ver" ]; then
            if pin_dockerfile_cc_version ".devcontainer/Dockerfile" "$latest_ver"; then
                ok "Dockerfile pinned to claude-code@$latest_ver (Docker will rebuild the affected layer only if version changed)"
            else
                warn "Dockerfile not found or not writable. Building with it as-is."
            fi
        else
            warn "Could not reach npm registry. Building with Dockerfile as-is."
        fi
    else
        info "Skipping version pin (--no-update). Building with Dockerfile as-is."
    fi

    # Pin versione rtk nel Dockerfile (solo se l'utente passa --use-rtk).
    # Stessa filosofia di cache-friendly del blocco Claude Code: il blocco rtk
    # e' delimitato da marker e viene riscritto solo se la versione su GitHub
    # e' cambiata. Default: rtk off, blocco rimosso dal Dockerfile (build pulita).
    if [ "$USE_RTK" = "true" ]; then
        info "Checking latest rtk version on GitHub..."
        rtk_ver=$(get_latest_rtk_version || true)
        if [ -n "$rtk_ver" ]; then
            if pin_dockerfile_rtk_version ".devcontainer/Dockerfile" "$rtk_ver"; then
                ok "Dockerfile pinned to rtk@$rtk_ver (image layer rebuilds only if rtk version changed)"
            else
                warn "Dockerfile not found or not writable. Building without rtk integration."
            fi
        else
            warn "Could not reach GitHub releases for rtk. Building with Dockerfile as-is."
        fi
    else
        info "rtk integration disabled (default). Removing rtk block from Dockerfile if present."
        remove_dockerfile_rtk_block ".devcontainer/Dockerfile"
    fi

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

    # Detect if this is a new profile (volume does not exist yet)
    local vol_suffix; vol_suffix=$(volume_suffix "$PROFILE")
    local config_vol="claudebox-shared-config-$vol_suffix"
    local is_new_profile=false
    if [ "$PROFILE" != "personal" ]; then
        if ! docker volume ls --format "{{.Name}}" 2>/dev/null | grep -qx "$config_vol"; then
            is_new_profile=true
            info "New profile '$PROFILE' -- seeding from personal config..."
            docker run --rm \
                -v "claudebox-shared-config-personal:/src:ro" \
                -v "${config_vol}:/dst" \
                alpine sh -c 'cp -a /src/. /dst/' >/dev/null
            ok "Volume '$config_vol' seeded from personal"
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
        -v "${CLAUDE_PLUGINS_DIR}:/host-claude-plugins:ro" \
        -v "${CCSTATUSLINE_CONFIG_DIR:-/dev/null}:/host-ccstatusline:ro" \
        -v "claudebox-shared-config-$(volume_suffix "$PROFILE"):/home/node/.claude" \
        -v "claudebox-shared-ccstatusline-$(volume_suffix "$PROFILE"):/home/node/.config/ccstatusline" \
        -v "claudebox-${proj}-history:/commandhistory" \
        -e CLAUDE_CONFIG_DIR="/home/node/.claude" \
        -e CLAUDE_PLUGINS_DIR="/home/node/.claude/plugins" \
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
    docker exec -u root "$cname" chown -R node:node /home/node/.claude/plugins >/dev/null
    docker exec "$cname" bash -c \
        'cp -rn /host-claude-plugins/. /home/node/.claude/plugins/ 2>/dev/null || true' >/dev/null
    docker exec -u root "$cname" chown -R node:node /home/node/.config/ccstatusline >/dev/null
    docker exec "$cname" bash -c \
        'if [ ! -f /home/node/.config/ccstatusline/settings.json ]; then cp -rn /host-ccstatusline/. /home/node/.config/ccstatusline/ 2>/dev/null || true; fi' >/dev/null

    # Fix host paths -> container paths in Claude Code JSON config files
    # Written to /tmp via heredoc to avoid single-quote issues in node -e
    docker exec -u node "$cname" bash -c 'cat > /tmp/claudebox-fix-paths.js' << 'JSEOF'
var fs = require("fs"), path = require("path");
var DIR = "/home/node/.claude";

var km = path.join(DIR, "plugins/known_marketplaces.json");
if (fs.existsSync(km)) {
  try {
    var d = JSON.parse(fs.readFileSync(km, "utf8"));
    for (var k in d) {
      if (d[k].installLocation)
        d[k].installLocation = DIR + "/plugins/marketplaces/" + k;
    }
    fs.writeFileSync(km, JSON.stringify(d, null, 2), "utf8");
  } catch(e) {}
}

var ip = path.join(DIR, "plugins/installed_plugins.json");
if (fs.existsSync(ip)) {
  try {
    var data = JSON.parse(fs.readFileSync(ip, "utf8"));
    var changed = false;
    for (var k in data.plugins) {
      (data.plugins[k] || []).forEach(function(e) {
        if (e.installPath) {
          var p = e.installPath.replace(/\\\\/g, "/").replace(/\\/g, "/").replace(/\/+/g, "/");
          var fixed = p.replace(/^(?:[A-Za-z]:\/|\/(?:Users|home)\/[^\/]+\/).*?\.claude/, DIR);
          if (fixed !== e.installPath) { e.installPath = fixed; changed = true; }
        }
      });
    }
    if (changed) fs.writeFileSync(ip, JSON.stringify(data, null, 2), "utf8");
  } catch(e) {}
}

var DIRS = ["plugins", "ide", "config"];
var RE = /(?:[A-Za-z]:[\\\/]|\/(?:Users|home)\/)(?:[^"\n])+/g;
function fixPath(m) {
  var p = m.replace(/\\\\/g, "/").replace(/\\/g, "/").replace(/\/+/g, "/");
  return p.replace(/^(?:[A-Za-z]:\/|\/(?:Users|home)\/[^\/]+\/).*?\.claude/, DIR);
}
function fixFile(f) {
  try {
    var r = fs.readFileSync(f, "utf8");
    RE.lastIndex = 0;
    if (!RE.test(r)) return;
    RE.lastIndex = 0;
    var x = r.replace(RE, fixPath);
    if (x !== r) fs.writeFileSync(f, x, "utf8");
  } catch(e) {}
}
function walk(d) {
  var e; try { e = fs.readdirSync(d, {withFileTypes:true}); } catch(x) { return; }
  for (var i = 0; i < e.length; i++) {
    var p = path.join(d, e[i].name);
    if (e[i].isDirectory()) walk(p);
    else if (e[i].name.slice(-5) === ".json") fixFile(p);
  }
}
for (var i = 0; i < DIRS.length; i++) walk(path.join(DIR, DIRS[i]));
JSEOF
    docker exec -u node "$cname" node /tmp/claudebox-fix-paths.js 2>/dev/null || true

    # Configure rtk hook in Claude Code settings (idempotent).
    # `rtk init -g --auto-patch` registra l'hook PreToolUse in
    # ~/.claude/settings.json e crea ~/.claude/RTK.md. E' idempotente: se
    # l'hook e' gia' presente, non fa nulla. La eseguiamo solo se l'utente ha
    # passato --use-rtk e rtk e' effettivamente installato nell'immagine.
    # Eseguita come node (l'utente del container) cosi' i file restano di
    # node:node nel volume condiviso /home/node/.claude.
    if [ "$USE_RTK" = "true" ] && docker exec "$cname" command -v rtk >/dev/null 2>&1; then
        info "Configuring rtk hook in Claude Code settings (idempotent)..."
        if docker exec -u node "$cname" rtk init -g --auto-patch >/dev/null 2>&1; then
            ok "rtk hook ready ($(docker exec "$cname" rtk --version 2>/dev/null | head -1))"
        else
            warn "rtk init failed; commands will not be auto-rewritten. You can retry inside the container with: rtk init -g --auto-patch"
        fi
    fi

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
    if $is_new_profile; then
        header "=== First login for profile '$PROFILE' ==="
        echo -e "  ${YELLOW}Please log in with your account for this profile.${NC}"
        echo -e "  ${YELLOW}After login, Claude Code will start automatically.\n${NC}"
        docker exec -it -u node "$cname" \
            zsh -c 'claude login && claude --dangerously-skip-permissions; exec zsh'
    else
        header "=== Launching Claude Code (--dangerously-skip-permissions) ==="
        echo -e "  ${YELLOW}Container is ready. Launching Claude Code...${NC}"
        echo -e "  ${YELLOW}Type 'exit' to leave the container shell.\n${NC}"
        docker exec -it -u node "$cname" \
            zsh -c 'claude --dangerously-skip-permissions; exec zsh'
    fi
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
        input_dir=$(read_input_or_default "  Enter Claude config path [default: $HOME/.claude]: " "$HOME/.claude")
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

    echo    "  Profile  : $PROFILE"
    echo    "  Config   : $CLAUDE_CONFIG_DIR"
    echo    "  Plugins  : $CLAUDE_CONFIG_DIR/plugins"
    echo -n "  ccstatus : "
    if [ -n "${CCSTATUSLINE_CONFIG_DIR:-}" ] && [ -d "${CCSTATUSLINE_CONFIG_DIR}" ]; then
        echo "$CCSTATUSLINE_CONFIG_DIR"
    else
        echo "(not found, will be skipped)"
    fi
    echo -n "  rtk      : "
    if $USE_RTK; then
        echo "enabled (--use-rtk): auto-install + auto-update on each up"
    else
        echo "disabled (default)"
    fi

    local has_devcontainer=false do_update=false
    [ -f "$dc_dir/devcontainer.json" ] && has_devcontainer=true

    # Ask about update if .devcontainer already exists
    if $has_devcontainer; then
        echo ""
        echo "  +- Dockerfile and init-firewall.sh may be outdated."
        echo "  |  Update official Anthropic files before starting?"
        if $AUTO_YES; then
            do_update=false
        else
            read -rp "  +- Update? [y/N] " update_answer
            # FIX: ${var,,} richiede bash 4+. Usiamo tr per portabilita' (macOS).
            _ans_lower=$(printf '%s' "$update_answer" | tr '[:upper:]' '[:lower:]')
            if [ "$_ans_lower" = "y" ]; then do_update=true; fi
        fi
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

    confirm_step "  Start? [Y/n] " || { info "Cancelled."; return; }

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
    echo  "  Shared volumes for profile '$PROFILE' are NOT removed."
    echo  "  To remove: docker volume rm claudebox-shared-config-$(volume_suffix \"$PROFILE\") claudebox-shared-ccstatusline-$(volume_suffix \"$PROFILE\")"
    confirm_step "Continue? [y/N] " || { info "Cancelled."; return; }

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

  INTEGRATIONS
    rtk (https://github.com/rtk-ai/rtk) is supported as an opt-in integration
    via --use-rtk. When enabled, rtk is installed in the container and the
    PreToolUse hook is registered in ~/.claude/settings.json so that bash
    commands like 'git status', 'cargo test', 'cat file.rs' are transparently
    rewritten to 'rtk git status', 'rtk cargo test', 'rtk read file.rs' for
    60-90% token savings. Default is OFF (rtk block removed from Dockerfile,
    no hook registered) -- enable explicitly with --use-rtk.

  FIRST RUN
    # Download and install (one-time):
    bash claudebox.sh install

    # Then from any project folder -- all in one command:
    cd ~/projects/my-project
    claudebox start
    claudebox start -y                    # skip all confirmations
    claudebox start -p work               # use work profile (~/.claude-work)
    claudebox start -p work -y            # work profile, no prompts
    claudebox start --no-update           # keep Claude Code version from image
    claudebox start --use-rtk             # opt-in to rtk install/update

    # Or step by step:
    claudebox init
    claudebox up

HELP
}

# ── ENTRY POINT ─────────────────────────────────────────────────────────────────
# Strip -y/--yes from positional args
_cmd="${1:-help}"
case "$_cmd" in
    install) cmd_install; exit 0 ;;
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
