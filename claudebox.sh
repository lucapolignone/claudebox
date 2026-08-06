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
# --detach flag: 'up' fa tutto il lavoro di preparazione ma si ferma prima
# dell'aggancio interattivo finale (vedi cmd_up). 'start' non lo eredita
# ancora -- e' lavoro successivo, non di questo commit.
AUTO_YES=false
NO_UPDATE=false
DETACH=false
PROFILE='personal'
for arg in "$@"; do
    case "$arg" in
        -y|--yes) AUTO_YES=true ;;
        -n|--no-update) NO_UPDATE=true ;;
        --detach) DETACH=true ;;
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

# ── Profile config (~/.config/claudebox/<profilo>.conf) ───────────────────────
# Formato file: una riga per chiave nel formato KEY=value, niente apici, niente
# commenti. Usato per persistere preferenze utente per-profilo (es. opt-in di
# iniezione credenziali GitLab). File creato lazy alla prima scrittura.
profile_conf_path() {
    local prof="${1:-$PROFILE}"
    echo "$HOME/.config/claudebox/${prof}.conf"
}

# profile_conf_get KEY [DEFAULT] -- stampa il valore della chiave o DEFAULT se
# mancante. Silenzioso se il file non esiste o la chiave non e' definita.
profile_conf_get() {
    local key="$1" default="${2:-}"
    local conf
    conf="$(profile_conf_path)"
    if [ ! -f "$conf" ]; then
        printf '%s' "$default"
        return 0
    fi
    local line
    line=$(grep -E "^${key}=" "$conf" 2>/dev/null | head -1)
    if [ -z "$line" ]; then
        printf '%s' "$default"
    else
        # Strip "KEY=" prefix, mantieni il resto come valore
        printf '%s' "${line#${key}=}"
    fi
}

# profile_conf_set KEY VALUE -- crea dir+file se mancanti, sostituisce la
# chiave esistente o appende. BSD vs GNU sed gestito esplicitamente (macOS).
profile_conf_set() {
    local key="$1" value="$2"
    local conf
    conf="$(profile_conf_path)"
    local dir
    dir="$(dirname "$conf")"
    if ! mkdir -p "$dir" 2>/dev/null; then
        warn "Cannot create $dir, preference will not persist"
        return 1
    fi
    if [ ! -f "$conf" ]; then
        : > "$conf"
    fi
    if grep -qE "^${key}=" "$conf" 2>/dev/null; then
        # Sostituzione in-place: gestire BSD (macOS) vs GNU sed
        if sed --version 2>/dev/null | grep -q GNU; then
            sed -i "s|^${key}=.*|${key}=${value}|" "$conf"
        else
            sed -i '' "s|^${key}=.*|${key}=${value}|" "$conf"
        fi
    else
        printf '%s=%s\n' "$key" "$value" >> "$conf"
    fi
}

# Chiede una volta sola se iniettare le credenziali GitLab dell'host e salva la
# scelta nel file di config del profilo. Default = yes. In non-TTY (pipe/CI) o
# con -y, salva il default senza prompt.
ensure_gitlab_creds_choice() {
    local current
    current=$(profile_conf_get INJECT_GITLAB_CREDS)
    if [ -n "$current" ]; then
        return 0
    fi

    if [ ! -t 0 ]; then
        profile_conf_set INJECT_GITLAB_CREDS yes
        return 0
    fi

    # read_input_or_default rispetta gia' $AUTO_YES (vedi claudebox.sh:53)
    local answer
    answer=$(read_input_or_default \
        "  Inject host GitLab credentials (\$GITLAB_TOKEN + ~/.config/glab-cli) into the container? [Y/n]: " \
        "yes")
    local lower
    lower=$(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]')
    case "$lower" in
        n|no) profile_conf_set INJECT_GITLAB_CREDS no ;;
        *)    profile_conf_set INJECT_GITLAB_CREDS yes ;;
    esac
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

# FIX: sed e' line-oriented -- un newline letterale nel nome della cartella
# (legale su Linux/macOS) attraversa 's/[^a-z0-9_-]/-/g' intatto, perche' il
# newline e' il separatore di riga per sed, mai un carattere del pattern
# space che quella sostituzione possa vedere. Lo convertiamo in '-' PRIMA di
# sed (un tr, che lavora byte per byte e non per riga, lo vede benissimo),
# cosi' anche una cartella con un a capo nel nome produce un project_name --
# e quindi nome container/immagine/volume -- su una sola riga, sano per
# Docker e per il JSON di 'info'. Allinea project_name() a Get-ProjectName in
# claudebox.ps1, la cui regex .NET su [^a-zA-Z0-9_\-] gia' considera il
# newline un carattere come un altro: stesso nome sanificato, non solo JSON
# valido in entrambi i casi.
project_name() {
    basename "$(pwd)" | tr '\n' '-' | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]/-/g' | sed 's/-\+/-/g' | sed 's/^-//;s/-$//'
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

# ── DOCKERFILE PATCHES: discovery + execution ───────────────────────────────────
# Cerca file che matchano 'patch-dockerfile*.sh' in DUE posizioni:
#   1. .devcontainer/   -> eseguiti con cwd=.devcontainer/
#                          (convenzione: patch usa DOCKERFILE="Dockerfile")
#   2. project root     -> eseguiti con cwd=project root
#                          (convenzione: patch usa DOCKERFILE=".devcontainer/Dockerfile")
# Entrambe le convenzioni coesistono. I patch sono eseguiti in ordine alfabetico,
# .devcontainer/ prima, project root poi. I patch DEVONO essere idempotenti.
# Eseguiamo via 'bash' per non dipendere dal bit +x.
run_dockerfile_patches() {
    local project_root="$1"
    local dc_dir="$project_root/.devcontainer"
    local header_shown=false
    local search_dir patch name rel rc

    for search_dir in "$dc_dir" "$project_root"; do
        [ -d "$search_dir" ] || continue
        # find + sort: ordine alfabetico portabile (BSD find su macOS, GNU su Linux)
        while IFS= read -r patch; do
            [ -z "$patch" ] && continue
            if ! $header_shown; then
                header "=== Applying Dockerfile patches ==="
                header_shown=true
            fi
            name=$(basename "$patch")
            rel="${patch#$project_root/}"
            info "Running: $rel"
            # Subshell + 'set +e' locale: anche se 'set -e' e' attivo nel parent,
            # un patch fallito non deve abortire claudebox. Catturiamo rc e warn.
            rc=0
            ( cd "$search_dir" && bash "./$name" patch ) || rc=$?
            if [ "$rc" -eq 0 ]; then
                ok "$name applicato"
            else
                warn "$name ha restituito exit code $rc"
            fi
        done < <(find "$search_dir" -maxdepth 1 -type f -name 'patch-dockerfile*.sh' 2>/dev/null | sort)
    done

    $header_shown && echo ""
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
  "postStartCommand": "sudo chown -R node:node /home/node/.claude /home/node/.config && mkdir -p /home/node/.local/bin /home/node/.config/ccstatusline /home/node/.claude/plugins && if [ ! -f /home/node/.claude/.credentials.json ]; then cp -rn /host-claude/. /home/node/.claude/ 2>/dev/null || true; fi && cp -rn /host-claude-plugins/. /home/node/.claude/plugins/ 2>/dev/null || true && if [ ! -f /home/node/.config/ccstatusline/settings.json ]; then cp -rn /host-ccstatusline/. /home/node/.config/ccstatusline/ 2>/dev/null || true; fi && mkdir -p /home/node/.config/glab-cli && if [ -d /host-glab-cli ]; then cp -rn /host-glab-cli/. /home/node/.config/glab-cli/ 2>/dev/null || true; fi && sudo /usr/local/bin/init-firewall.sh 2>/dev/null || true",
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

    # Chiedere preferenza iniezione credenziali GitLab (persistita per profilo)
    ensure_gitlab_creds_choice

    # Apply project-specific Dockerfile patches (idempotent, see README)
    run_dockerfile_patches "$(pwd)"

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

    # Safety net: ri-applica patch project-specific (caso: aggiunti dopo init,
    # oppure update upstream ha sovrascritto il Dockerfile da un'altra sessione).
    # I patch sono idempotenti, quindi se gia' applicati e' un no-op.
    run_dockerfile_patches "$(pwd)"

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

    # Docker-outside-of-Docker (DooD) support
    # Se il Dockerfile contiene il marker del patch docker, montiamo il socket
    # dell'host dentro al container e allineiamo il GID del gruppo 'docker'
    # con quello del docker.sock dell'host (necessario su Linux).
    # Su macOS/Windows con Docker Desktop il GID alignment non e' richiesto:
    # il socket e' esposto world-rw dalla VM, ma --group-add non fa danno.
    local docker_extra_opts=()
    if [ -f ".devcontainer/Dockerfile" ] \
       && grep -qF "CLAUDEBOX_PATCH_DOCKER_BEGIN" ".devcontainer/Dockerfile"; then
        if [ -S /var/run/docker.sock ]; then
            docker_extra_opts+=( -v "/var/run/docker.sock:/var/run/docker.sock" )
            info "Docker patch detected: mounting host docker.sock (DooD)"
            # GID detection portabile: GNU stat (Linux) vs BSD stat (macOS).
            local sock_gid=""
            sock_gid=$(stat -c '%g' /var/run/docker.sock 2>/dev/null \
                       || stat -f '%g' /var/run/docker.sock 2>/dev/null \
                       || true)
            if [ -n "$sock_gid" ] && [ "$sock_gid" != "0" ]; then
                docker_extra_opts+=( --group-add "$sock_gid" )
                info "  + --group-add $sock_gid (matching host docker.sock GID)"
            fi
        else
            warn "Docker patch detected but /var/run/docker.sock not found on host."
            warn "Docker CLI inside the container will fail to reach a daemon."
        fi
    fi

    # GitLab credentials injection (opt-in per-profile, see profile conf)
    local inject_glab
    inject_glab=$(profile_conf_get INJECT_GITLAB_CREDS no)
    if [ "$inject_glab" = "yes" ]; then
        local glab_dir="$HOME/.config/glab-cli"
        local has_dir=0 has_token=0
        if [ -d "$glab_dir" ]; then
            docker_extra_opts+=( -v "${glab_dir}:/host-glab-cli:ro" )
            has_dir=1
        fi
        if [ -n "${GITLAB_TOKEN:-}" ]; then
            docker_extra_opts+=( -e "GITLAB_TOKEN=${GITLAB_TOKEN}" )
            has_token=1
        fi
        if [ "$has_dir" = "1" ] || [ "$has_token" = "1" ]; then
            local _hd _ht
            [ "$has_dir"   = "1" ] && _hd=yes || _hd=no
            [ "$has_token" = "1" ] && _ht=yes || _ht=no
            info "GitLab credentials injected (glab-cli config: $_hd, GITLAB_TOKEN env: $_ht)"
        else
            warn "INJECT_GITLAB_CREDS=yes but neither \$GITLAB_TOKEN nor ~/.config/glab-cli/ available on host — skipping"
        fi
    fi

    # Absolute path of the project folder, used below for the claudebox.workspace
    # label. Calcolato una volta in una variabile: non va messo inline dentro le
    # righe di continuazione del docker run.
    local workspace_dir
    workspace_dir="$(pwd)"

    # Start container
    info "Starting container '$cname'..."
    docker run -d \
        --name "$cname" \
        --cap-add=NET_ADMIN \
        --cap-add=NET_RAW \
        --label "claudebox.project=$proj" \
        --label "claudebox.profile=$PROFILE" \
        --label "claudebox.workspace=$workspace_dir" \
        ${docker_extra_opts[@]+"${docker_extra_opts[@]}"} \
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

    # Docker.sock alignment (DooD): se il patch docker e' applicato, allinea il
    # socket dentro al container al gruppo 'docker'. Necessario su Docker
    # Desktop / sandbox via proxy, dove il bind-mount espone il socket come
    # root:root 660 indipendentemente dal GID reale dell'host -- quindi
    # --group-add (passato in docker run) da solo non basta. Idempotente.
    if [ -f ".devcontainer/Dockerfile" ] \
       && grep -qF "CLAUDEBOX_PATCH_DOCKER_BEGIN" ".devcontainer/Dockerfile"; then
        if docker exec -u root "$cname" bash -c '
            [ -S /var/run/docker.sock ] || exit 0
            cur=$(stat -c "%G" /var/run/docker.sock 2>/dev/null || echo "?")
            [ "$cur" = "docker" ] && exit 0
            chgrp docker /var/run/docker.sock && chmod 660 /var/run/docker.sock
        ' 2>/dev/null; then
            ok "Docker socket aligned to 'docker' group (node user can use docker)"
        else
            warn "Could not align docker.sock group inside container."
            warn "Inside the container, run: sudo chgrp docker /var/run/docker.sock && sudo chmod 660 /var/run/docker.sock"
        fi
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

    # GitLab credentials post-start copy (safety-net per devcontainer.json
    # generati da claudebox precedenti, che non hanno la copia in postStartCommand).
    # Idempotente: cp -rn no-clobber. Posizionato dopo il chown di /home/node/.config
    # cosi' la mkdir come utente node non fallisce su container appena creati.
    if [ "${inject_glab:-no}" = "yes" ]; then
        docker exec -u node "$cname" bash -c \
            'mkdir -p /home/node/.config/glab-cli && if [ -d /host-glab-cli ]; then cp -rn /host-glab-cli/. /home/node/.config/glab-cli/ 2>/dev/null || true; fi' >/dev/null 2>&1 || true
    fi

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

    # Verify isolation
    header "=== Container isolation check ==="
    local workdir
    workdir=$(docker exec -u node "$cname" pwd)
    if [ "${workdir}" = "/workspace" ]; then
        ok "Isolation confirmed: pwd = /workspace"
    else
        err "Isolation NOT verified: pwd = '$workdir' (expected /workspace)"
    fi

    # --detach: tutto quello che serve per rendere il container utilizzabile
    # e' gia' girato sopra (build, run, firewall, chown, credenziali,
    # correzione dei percorsi, verifica isolamento). Ci si ferma qui, PRIMA
    # dell'aggancio interattivo che segue -- quello non parte mai con
    # --detach. Uscita 0 solo se il container e' davvero acceso.
    if $DETACH; then
        if container_running; then
            ok "Container '$cname' is up (--detach, no interactive attach)."
            return 0
        else
            err "Container '$cname' non risulta acceso dopo l'avvio (--detach)."
        fi
    fi

    # Launch Claude Code
    if $is_new_profile; then
        header "=== First login for profile '$PROFILE' ==="
        echo -e "  ${YELLOW}Please log in with your account for this profile.${NC}"
        echo -e "  ${YELLOW}After login, Claude Code will start automatically.\n${NC}"
        docker exec -it -u node \
            -e CLAUDE_CODE_NO_FLICKER=1 \
            "$cname" \
            zsh -c 'claude login && claude --dangerously-skip-permissions; exec zsh'
    else
        header "=== Launching Claude Code (--dangerously-skip-permissions) ==="
        echo -e "  ${YELLOW}Container is ready. Launching Claude Code...${NC}"
        echo -e "  ${YELLOW}Type 'exit' to leave the container shell.\n${NC}"
        # CLAUDE_CODE_NO_FLICKER=1 fa partire Claude Code direttamente in
        # alternate-screen / fullscreen mode senza il transient flicker iniziale.
        docker exec -it -u node \
            -e CLAUDE_CODE_NO_FLICKER=1 \
            "$cname" \
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

    # Re-apply project-specific patches (the download just wiped them)
    run_dockerfile_patches "$(pwd)"

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

    # Chiedere preferenza iniezione credenziali GitLab al primo start del profilo
    ensure_gitlab_creds_choice

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

# ── JSON HELPERS ─────────────────────────────────────────────────────────────────
# json_string STR -- sfugge \ e " cosi' che STR sia sicuro dentro un valore
# JSON tra virgolette. L'ordine conta: si sfugge prima il backslash, altrimenti
# il backslash appena inserito davanti alle virgolette verrebbe sfuggito a sua
# volta ("doppia fuga").
#
# Sfugge anche i caratteri di controllo C0 (0x00-0x1F): 'workspace' viene dal
# percorso reale della cartella ($(pwd)), che a differenza di project_name()
# non e' sanificato -- e su Linux/macOS un newline (o un tab, o un qualsiasi
# controllo) nel nome di una cartella e' legale. Senza questo, un simile
# nome romperebbe il JSON prodotto (provato: "Invalid control character").
# \n, \r, \t hanno una forma corta leggibile; il resto del range C0 diventa
# \u00XX secondo RFC 8259. Non serve gestire NUL (0x00): una stringa bash
# non puo' contenerlo.
json_string() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    local out='' i n c ord
    n=${#s}
    for ((i = 0; i < n; i++)); do
        c="${s:i:1}"
        ord=$(printf '%d' "'$c")
        if (( ord >= 0 && ord < 32 )); then
            printf -v c '\\u%04x' "$ord"
        fi
        out+="$c"
    done
    printf '%s' "$out"
}

# ── INFO ────────────────────────────────────────────────────────────────────────
# Dice cio' che claudebox sa di un progetto, senza che nessun altro programma
# debba indovinarlo (nome sanificato, nome container, volume, cartella...).
# Con --json stampa SOLO JSON su stdout: nessun banner, nessun messaggio --
# quelli, se servissero, andrebbero su stderr. Legge solo, non tocca Docker.
cmd_info() {
    local json_mode=false
    for arg in "$@"; do
        [ "$arg" = "--json" ] && json_mode=true
    done

    local proj cname img vol workspace exists running
    proj="$(project_name)"
    cname="$(container_name)"
    img="claudebox-img-$proj"
    vol="claudebox-${proj}-history"
    workspace="$(pwd)"
    container_exists  && exists=true  || exists=false
    container_running && running=true || running=false

    if $json_mode; then
        printf '{\n'
        printf '  "progetto":  "%s",\n' "$(json_string "$proj")"
        printf '  "profilo":   "%s",\n' "$(json_string "$PROFILE")"
        printf '  "container": "%s",\n' "$(json_string "$cname")"
        printf '  "immagine":  "%s",\n' "$(json_string "$img")"
        printf '  "volume":    "%s",\n' "$(json_string "$vol")"
        printf '  "workspace": "%s",\n' "$(json_string "$workspace")"
        printf '  "esiste":    %s,\n' "$exists"
        printf '  "acceso":    %s\n' "$running"
        printf '}\n'
    else
        header "=== claudebox info ==="
        echo "  Progetto  : $proj"
        echo "  Profilo   : $PROFILE"
        echo "  Container : $cname"
        echo "  Immagine  : $img"
        echo "  Volume    : $vol"
        echo "  Workspace : $workspace"
        echo "  Esiste    : $exists"
        echo "  Acceso    : $running"
    fi
}

# ── LS ──────────────────────────────────────────────────────────────────────────
# _ls_emit JSON_MODE SEP NAME RUNNING PROJECT_LABEL PROFILE_LABEL WORKSPACE_LABEL IMAGE HISTORY_VOL
# Stampa un elemento dell'elenco di cmd_ls (un oggetto JSON dell'array, o una
# voce leggibile). E' una funzione a se' perche' viene invocata una volta per
# record durante la lettura NUL-delimited dell'unico 'docker inspect' (vedi
# cmd_ls). SEP e' '' per il primo elemento, ',\n' per i successivi.
_ls_emit() {
    local json_mode="$1" sep="$2" name="$3" running="$4"
    local plabel="$5" proflabel="$6" wslabel="$7" image="$8" history="$9"
    local cname proj prof workspace acceso

    cname="${name#/}"

    if [ -n "$plabel" ]; then
        # Etichettato (le tre label si mettono sempre insieme, vedi Task 1):
        # niente da indovinare.
        proj="$plabel"
        prof="$proflabel"
        workspace="$wslabel"
    else
        # Container precedente a questo lavoro, senza etichette. Si deduce
        # dal nome solo cio' che e' davvero inequivocabile: container_name()
        # produce "claudebox-<progetto>" quando il profilo e' 'personal', e
        # "claudebox-<progetto>-<profilo>" altrimenti. Un resto SENZA trattini
        # interni puo' venire solo dal primo caso (un progetto senza trattini
        # suoi, profilo 'personal'): l'unica deduzione che non e' una
        # scommessa. Un resto CON trattini e' strutturalmente ambiguo -- puo'
        # essere un progetto con trattini suoi, o un progetto piu' un
        # suffisso profilo -- e non c'e' modo di saperlo dal nome soltanto:
        # profilo resta null, progetto e' il resto per intero (il meglio che
        # si puo' fare senza indovinare quale pezzo sia quale).
        local rest="${cname#claudebox-}"
        proj="$rest"
        case "$rest" in
            *-*) prof='' ;;
            *)   prof='personal' ;;
        esac
        workspace=''
    fi

    if [ "$running" = "true" ]; then acceso=true; else acceso=false; fi

    if $json_mode; then
        printf '%s  {\n' "$sep"
        printf '    "progetto":  "%s",\n' "$(json_string "$proj")"
        if [ -n "$prof" ]; then printf '    "profilo":   "%s",\n' "$(json_string "$prof")"
        else printf '    "profilo":   null,\n'; fi
        printf '    "container": "%s",\n' "$(json_string "$cname")"
        if [ -n "$image" ]; then printf '    "immagine":  "%s",\n' "$(json_string "$image")"
        else printf '    "immagine":  null,\n'; fi
        if [ -n "$history" ]; then printf '    "volume":    "%s",\n' "$(json_string "$history")"
        else printf '    "volume":    null,\n'; fi
        if [ -n "$workspace" ]; then printf '    "workspace": "%s",\n' "$(json_string "$workspace")"
        else printf '    "workspace": null,\n'; fi
        printf '    "esiste":    true,\n'
        printf '    "acceso":    %s\n' "$acceso"
        printf '  }'
    else
        echo "  - $cname"
        echo "      Progetto  : $proj"
        echo "      Profilo   : ${prof:-(sconosciuto)}"
        echo "      Immagine  : ${image:-(sconosciuta)}"
        echo "      Volume    : ${history:-(sconosciuto)}"
        echo "      Workspace : ${workspace:-(sconosciuto)}"
        echo "      Acceso    : $acceso"
    fi
}

# Elenca tutti i container claudebox della macchina, uno per sandbox. La
# scoperta e' per PREFISSO del nome ('claudebox-'), non per etichetta:
# filtrare per label=claudebox.project sembrerebbe piu' pulito ma farebbe
# sparire dall'elenco ogni container creato prima di questo lavoro, che
# etichette non ne ha mai avute. Il prefisso li trova tutti; le etichette,
# quando ci sono, riempiono i campi che dal nome non si possono ricavare.
cmd_ls() {
    local json_mode=false
    for arg in "$@"; do
        [ "$arg" = "--json" ] && json_mode=true
    done

    local names_raw
    names_raw=$(docker ps -a --filter 'name=^claudebox-' --format '{{.Names}}' 2>/dev/null)

    if [ -z "$names_raw" ]; then
        if $json_mode; then
            printf '[]\n'
        else
            header "=== claudebox ls ==="
            echo "  Nessun container claudebox su questa macchina."
        fi
        return 0
    fi

    local -a cnames=()
    while IFS= read -r n; do
        [ -n "$n" ] && cnames+=("$n")
    done <<< "$names_raw"

    # Un solo 'docker inspect' per TUTTI i container, non uno a testa: si
    # sente su una macchina con dieci sandbox. Il template usa \u0000 come
    # separatore di campo E di record -- l'unico byte che non puo' comparire
    # in nessuno dei valori (percorsi, nomi, label): un separatore stampabile
    # si romperebbe su un workspace con un tab o un a capo dentro (lo stesso
    # caso per cui json_string() sfugge i controlli C0).
    local fmt
    fmt='{{.Name}}{{"\u0000"}}{{.State.Running}}{{"\u0000"}}{{index .Config.Labels "claudebox.project"}}{{"\u0000"}}{{index .Config.Labels "claudebox.profile"}}{{"\u0000"}}{{index .Config.Labels "claudebox.workspace"}}{{"\u0000"}}{{.Config.Image}}{{"\u0000"}}{{range .Mounts}}{{if eq .Destination "/commandhistory"}}{{.Name}}{{end}}{{end}}{{"\u0000"}}'

    $json_mode && printf '[\n'
    $json_mode || header "=== claudebox ls ==="

    local field_idx=0 sep=''
    local f_name f_running f_project f_profile f_workspace f_image f_history
    while IFS= read -r -d '' field; do
        case $(( field_idx % 7 )) in
            0)
                # 'docker inspect --format' con piu' nomi aggiunge un \n suo
                # dopo l'output di OGNI oggetto, oltre al nostro NUL
                # esplicito -- verificato con 'od -c'. Quel \n finisce quindi
                # incollato davanti al primo campo del record successivo (il
                # nostro delimitatore vede solo NUL, non \n). Un nome
                # container vero non inizia mai per \n, quindi va tolto se
                # presente: e' rumore di docker, non parte del valore.
                f_name="${field#$'\n'}"
                ;;
            1) f_running="$field" ;;
            2) f_project="$field" ;;
            3) f_profile="$field" ;;
            4) f_workspace="$field" ;;
            5) f_image="$field" ;;
            6)
                f_history="$field"
                _ls_emit "$json_mode" "$sep" "$f_name" "$f_running" \
                    "$f_project" "$f_profile" "$f_workspace" "$f_image" "$f_history"
                sep=$',\n'
                ;;
        esac
        field_idx=$((field_idx + 1))
    done < <(docker inspect --format "$fmt" "${cnames[@]}" 2>/dev/null)

    $json_mode && printf '\n]\n'
    return 0
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

  GITLAB CREDENTIALS
    init/start chiede una volta sola se iniettare \$GITLAB_TOKEN e ~/.config/glab-cli
    nel container. La scelta e' salvata per profilo in ~/.config/claudebox/<profilo>.conf
    (chiave INJECT_GITLAB_CREDS=yes|no). Per cambiarla, edita quel file a mano.

  ENVIRONMENT VARIABLES
    CLAUDE_CONFIG_DIR         Claude Code config directory (default: ~/.claude)
    CCSTATUSLINE_CONFIG_DIR   ccstatusline config directory (default: ~/.config/ccstatusline)
    GITLAB_TOKEN              GitLab personal access token (iniettato nel container se opt-in)

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
    info)    cmd_info "$@" ;;
    ls)      cmd_ls "$@"   ;;
    help|--help|-h) cmd_help ;;
    *) cmd_help ;;
esac
