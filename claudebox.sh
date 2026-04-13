#!/usr/bin/env bash
# claudebox — devcontainer Claude Code per la cartella corrente
# macOS e Linux/Unix
#
# Uso:
#   Prima esecuzione (auto-installazione):
#     bash claudebox.sh
#
#   Dopo l'installazione, da qualsiasi cartella:
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
        curl -fsSL "$url" -o "$dest" || err "Impossibile scaricare $label da:\n  $url\nVerifica la connessione e riprova."
    elif command -v wget &>/dev/null; then
        wget -q "$url" -O "$dest" || err "Impossibile scaricare $label da:\n  $url\nVerifica la connessione e riprova."
    else
        err "curl o wget non trovati. Installane uno e riprova."
    fi
    ok "$label scaricato da GitHub ufficiale"
}

# ── AUTO-INSTALLAZIONE ──────────────────────────────────────────────────────────
cmd_install() {
    header "=== Installazione claudebox ==="

    local source_script
    source_script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

    # Cerca una directory installazione nel PATH utente
    local install_dir=""
    for candidate in "$HOME/.local/bin" "$HOME/bin"; do
        if [ -d "$candidate" ]; then
            install_dir="$candidate"
            break
        fi
    done
    # Nessuna trovata: crea ~/.local/bin
    if [ -z "$install_dir" ]; then
        install_dir="$HOME/.local/bin"
        mkdir -p "$install_dir"
        ok "Creata directory: $install_dir"
    fi

    local dest="$install_dir/claudebox"
    info "Copia script in: $dest"
    cp "$source_script" "$dest"
    chmod +x "$dest"
    ok "Script copiato e reso eseguibile"

    # Aggiungi al PATH se non presente
    local shell_rc=""
    if [ -n "${ZSH_VERSION:-}" ] || [ "$(basename "${SHELL:-}")" = "zsh" ]; then
        shell_rc="$HOME/.zshrc"
    else
        shell_rc="$HOME/.bashrc"
    fi

    local path_line="export PATH=\"\$HOME/.local/bin:\$HOME/bin:\$PATH\""
    if ! grep -q 'claudebox\|\.local/bin' "$shell_rc" 2>/dev/null; then
        echo "" >> "$shell_rc"
        echo "# claudebox (aggiunto da claudebox.sh)" >> "$shell_rc"
        echo "$path_line" >> "$shell_rc"
        ok "PATH aggiornato in: $shell_rc"
    else
        info "PATH gia configurato in $shell_rc"
    fi

    # Rendi disponibile nella sessione corrente
    export PATH="$HOME/.local/bin:$HOME/bin:$PATH"

    echo ""
    ok "Installazione completata!"
    echo ""
    echo -e "  Riavvia il terminale (o esegui: source $shell_rc) per usare"
    echo    "  il comando 'claudebox' da qualsiasi cartella."
    echo ""
    echo    "  Uso rapido:"
    echo -e "    cd ~/progetti/mio-progetto"
    echo -e "    claudebox start"
    echo ""
}

# ── PREREQUISITI ────────────────────────────────────────────────────────────────
check_prerequisites() {
    header "=== Controllo prerequisiti ==="

    command -v docker &>/dev/null || err "Docker non trovato. Installalo da https://www.docker.com/products/docker-desktop"
    ok "Docker trovato: $(docker --version)"

    docker info &>/dev/null || err "Il daemon Docker non risponde. Avvia Docker Desktop e riprova."
    ok "Docker daemon attivo"

    # CLAUDE_CONFIG_DIR
    if [ -z "${CLAUDE_CONFIG_DIR:-}" ]; then
        for candidate in "$HOME/.claude" "$HOME/.config/claude"; do
            if [ -d "$candidate" ]; then
                export CLAUDE_CONFIG_DIR="$candidate"
                warn "CLAUDE_CONFIG_DIR non impostata; uso: $candidate"
                break
            fi
        done
        if [ -z "${CLAUDE_CONFIG_DIR:-}" ]; then
            err "CLAUDE_CONFIG_DIR non impostata e nessuna cartella Claude trovata.\nImposta la variabile:\n  export CLAUDE_CONFIG_DIR=~/.claude\nAggiungi la riga al tuo .zshrc/.bashrc per renderla permanente."
        fi
    fi
    [ -d "$CLAUDE_CONFIG_DIR" ] || err "CLAUDE_CONFIG_DIR='$CLAUDE_CONFIG_DIR' non esiste."
    ok "CLAUDE_CONFIG_DIR -> $CLAUDE_CONFIG_DIR"

    # CCSTATUSLINE_CONFIG_DIR (opzionale)
    if [ -z "${CCSTATUSLINE_CONFIG_DIR:-}" ]; then
        local cc_default="$HOME/.config/ccstatusline"
        if [ -d "$cc_default" ]; then
            export CCSTATUSLINE_CONFIG_DIR="$cc_default"
            warn "CCSTATUSLINE_CONFIG_DIR non impostata; uso: $cc_default"
        else
            warn "CCSTATUSLINE_CONFIG_DIR non impostata e $cc_default non trovata. ccstatusline non sara configurato."
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

    header "=== Inizializzazione devcontainer per '$proj' ==="

    if [ -d "$dc_dir" ]; then
        warn "La cartella .devcontainer esiste gia."
        read -rp "Sovrascrivere i file? [y/N] " answer
        [ "${answer,,}" = "y" ] || { info "Annullato."; return; }
    fi
    mkdir -p "$dc_dir"

    # Dockerfile e init-firewall.sh: scaricati da Anthropic
    info "Scarico i file ufficiali da anthropics/claude-code..."
    download_file "$ANTHROPIC_RAW_BASE/Dockerfile"       "$dc_dir/Dockerfile"       "Dockerfile"
    download_file "$ANTHROPIC_RAW_BASE/init-firewall.sh" "$dc_dir/init-firewall.sh" "init-firewall.sh"
    chmod +x "$dc_dir/init-firewall.sh"

    # devcontainer.json: generato con le nostre personalizzazioni
    info "Genero devcontainer.json personalizzato..."
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

    ok "Generato .devcontainer/devcontainer.json (personalizzato)"
    ok "Scaricato .devcontainer/Dockerfile (ufficiale Anthropic)"
    ok "Scaricato .devcontainer/init-firewall.sh (ufficiale Anthropic)"
    echo ""
    info "Prossimo passo: claudebox up"
}

# ── UP ──────────────────────────────────────────────────────────────────────────
cmd_up() {
    check_prerequisites

    [ -f ".devcontainer/devcontainer.json" ] || err "Nessun .devcontainer trovato. Esegui prima: claudebox init"

    local proj cname
    proj="$(project_name)"
    cname="$(container_name)"

    header "=== Avvio devcontainer '$proj' ==="

    # Build
    info "Build immagine Docker (qualche minuto alla prima esecuzione)..."
    docker build -t "claudebox-img-$proj" .devcontainer/
    ok "Immagine pronta: claudebox-img-$proj"

    # Probe: verifica che Docker possa accedere a CLAUDE_CONFIG_DIR
    info "Verifica che Docker possa accedere a CLAUDE_CONFIG_DIR..."
    if ! docker run --rm \
            -v "${CLAUDE_CONFIG_DIR}:/probe:ro" \
            "claudebox-img-$proj" \
            ls /probe &>/dev/null; then
        echo ""
        echo -e "  ${RED}ERR${NC} Docker non riesce ad accedere alla cartella:"
        echo    "      $CLAUDE_CONFIG_DIR"
        echo ""
        echo    "  Su macOS: Docker Desktop -> Settings -> Resources -> File Sharing"
        echo    "  Su Linux: assicurati che la cartella esista e Docker abbia i permessi"
        echo    "  Aggiungi: $CLAUDE_CONFIG_DIR"
        echo ""
        exit 1
    fi
    ok "Docker ha accesso a CLAUDE_CONFIG_DIR"

    # Probe ccstatusline (non bloccante)
    if [ -d "${CCSTATUSLINE_CONFIG_DIR:-}" ]; then
        if ! docker run --rm \
                -v "${CCSTATUSLINE_CONFIG_DIR}:/probe-cs:ro" \
                "claudebox-img-$proj" \
                ls /probe-cs &>/dev/null; then
            warn "Docker non riesce ad accedere a CCSTATUSLINE_CONFIG_DIR ($CCSTATUSLINE_CONFIG_DIR)."
            warn "ccstatusline procedera senza config personalizzata."
        else
            ok "Docker ha accesso a CCSTATUSLINE_CONFIG_DIR"
        fi
    fi

    # Rimuovi container precedente
    if container_exists; then
        info "Rimozione container precedente '$cname'..."
        docker rm -f "$cname" >/dev/null
    fi

    # Avvia container
    info "Avvio container '$cname'..."
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
    ok "Container avviato"

    # Firewall
    info "Inizializzazione firewall..."
    if docker exec "$cname" sudo /usr/local/bin/init-firewall.sh &>/dev/null; then
        ok "Firewall applicato"
    else
        warn "Firewall non applicato (NET_ADMIN potrebbe non essere disponibile)."
    fi

    # Copia config al primo avvio
    docker exec "$cname" bash -c \
        'sudo chown -R node:node /home/node/.claude /home/node/.config 2>/dev/null || true' >/dev/null
    docker exec "$cname" bash -c \
        'mkdir -p /home/node/.local/bin /home/node/.config/ccstatusline' >/dev/null
    docker exec "$cname" bash -c \
        'if [ ! -f /home/node/.claude/.credentials.json ]; then cp -rn /host-claude/. /home/node/.claude/ 2>/dev/null || true; fi' >/dev/null
    docker exec "$cname" bash -c \
        'if [ ! -f /home/node/.config/ccstatusline/settings.json ]; then cp -rn /host-ccstatusline/. /home/node/.config/ccstatusline/ 2>/dev/null || true; fi' >/dev/null

    # Fix path in JSON (su macOS/Linux i path sono gia corretti, ma per sicurezza)
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

    # Verifica isolamento
    header "=== Verifica isolamento container ==="
    local workdir
    workdir=$(docker exec -u node "$cname" pwd)
    if [ "${workdir}" = "/workspace" ]; then
        ok "Isolamento confermato: pwd = /workspace"
    else
        err "Isolamento NON verificato: pwd = '$workdir' (atteso /workspace)"
    fi

    # Lancio Claude Code
    header "=== Avvio Claude Code (--dangerously-skip-permissions) ==="
    echo -e "  ${YELLOW}Il container e pronto. Lancio Claude Code...${NC}"
    echo -e "  ${YELLOW}Digita 'exit' per uscire dalla shell del container.${NC}\n"
    docker exec -it -u node "$cname" \
        zsh -c 'claude --dangerously-skip-permissions; exec zsh'
}

# ── UPDATE ──────────────────────────────────────────────────────────────────────
cmd_update() {
    local dc_dir
    dc_dir="$(pwd)/.devcontainer"

    header "=== Aggiornamento file ufficiali Anthropic ==="

    [ -d "$dc_dir" ] || err "Nessun .devcontainer trovato. Esegui prima: claudebox init"

    info "Scarico versioni aggiornate da anthropics/claude-code (main)..."
    download_file "$ANTHROPIC_RAW_BASE/Dockerfile"       "$dc_dir/Dockerfile"       "Dockerfile"
    download_file "$ANTHROPIC_RAW_BASE/init-firewall.sh" "$dc_dir/init-firewall.sh" "init-firewall.sh"
    chmod +x "$dc_dir/init-firewall.sh"

    echo ""
    ok "File ufficiali aggiornati. devcontainer.json non modificato."
    info "Esegui 'claudebox up' per ricostruire l'immagine con le modifiche."
}

# ── START ───────────────────────────────────────────────────────────────────────
cmd_start() {
    local proj dc_dir
    proj="$(project_name)"
    dc_dir="$(pwd)/.devcontainer"

    # Banner
    echo ""
    echo -e "  ${BLUE}+======================================================+${NC}"
    echo -e "  ${BLUE}|         claudebox  --  avvio automatico             |${NC}"
    echo -e "  ${BLUE}+======================================================+${NC}"
    echo ""
    echo -e "  Progetto : ${BOLD}$proj${NC}"
    echo    "  Cartella : $(pwd)"

    # Risolvi CLAUDE_CONFIG_DIR
    if [ -z "${CLAUDE_CONFIG_DIR:-}" ]; then
        for candidate in "$HOME/.claude" "$HOME/.config/claude"; do
            if [ -d "$candidate" ]; then
                export CLAUDE_CONFIG_DIR="$candidate"
                break
            fi
        done
    fi

    # Se ancora non trovata, chiedi
    if [ -z "${CLAUDE_CONFIG_DIR:-}" ] || [ ! -d "${CLAUDE_CONFIG_DIR}" ]; then
        echo ""
        warn "CLAUDE_CONFIG_DIR non configurata o non trovata automaticamente."
        echo ""
        echo "  Claude Code salva credenziali e configurazioni in una cartella dedicata."
        echo "  Di solito si trova in: $HOME/.claude"
        echo ""
        read -rp "  Inserisci il percorso della config Claude [default: $HOME/.claude]: " input_dir
        input_dir="${input_dir:-$HOME/.claude}"
        if [ ! -d "$input_dir" ]; then
            warn "La cartella '$input_dir' non esiste. La creo ora."
            mkdir -p "$input_dir"
        fi
        export CLAUDE_CONFIG_DIR="$input_dir"
        # Salva permanentemente
        local shell_rc
        if [ "$(basename "${SHELL:-}")" = "zsh" ]; then shell_rc="$HOME/.zshrc"; else shell_rc="$HOME/.bashrc"; fi
        echo "" >> "$shell_rc"
        echo "export CLAUDE_CONFIG_DIR=\"$input_dir\"" >> "$shell_rc"
        ok "CLAUDE_CONFIG_DIR impostata permanentemente in $shell_rc"
    fi

    # Risolvi CCSTATUSLINE_CONFIG_DIR
    if [ -z "${CCSTATUSLINE_CONFIG_DIR:-}" ]; then
        local cc_default="$HOME/.config/ccstatusline"
        [ -d "$cc_default" ] && export CCSTATUSLINE_CONFIG_DIR="$cc_default"
    fi

    echo    "  Config   : $CLAUDE_CONFIG_DIR"
    echo -n "  ccstatus : "
    if [ -n "${CCSTATUSLINE_CONFIG_DIR:-}" ] && [ -d "${CCSTATUSLINE_CONFIG_DIR}" ]; then
        echo "$CCSTATUSLINE_CONFIG_DIR"
    else
        echo "(non trovata, verra saltata)"
    fi

    local has_devcontainer=false do_update=false
    [ -f "$dc_dir/devcontainer.json" ] && has_devcontainer=true

    # Chiedi update se .devcontainer esiste gia
    if $has_devcontainer; then
        echo ""
        echo "  +- Dockerfile e init-firewall.sh potrebbero essere datati."
        echo "  |  Aggiornare i file ufficiali da Anthropic prima di avviare?"
        read -rp "  +- Update? [y/N] " update_answer
        [ "${update_answer,,}" = "y" ] && do_update=true
    fi

    # Stato attuale
    echo ""
    echo "  Stato attuale:"
    echo -n "    .devcontainer : "
    $has_devcontainer && echo "presente" || echo "assente  -> verra creato"
    echo -n "    Container     : "
    if container_running; then echo "in esecuzione -> verra ricreato"
    elif container_exists; then echo "fermo     -> verra ricreato"
    else echo "assente   -> verra creato"; fi

    # Riepilogo passi
    local step=1
    echo ""
    echo "  Passi che verranno eseguiti:"
    if ! $has_devcontainer; then
        echo "    $step. init   -- scarica file ufficiali Anthropic e genera devcontainer.json"; ((step++))
    elif $do_update; then
        echo "    $step. update -- ri-scarica Dockerfile e init-firewall.sh da Anthropic"; ((step++))
    fi
    echo "    $step. build  -- costruisce l'immagine Docker"; ((step++))
    echo "    $step. run    -- avvia il container e monta le cartelle"; ((step++))
    echo "    $step. check  -- verifica isolamento (pwd = /workspace)"; ((step++))
    echo "    $step. claude -- lancia claude --dangerously-skip-permissions"
    echo ""

    read -rp "  Avviare? [Y/n] " confirm
    [ "${confirm,,}" = "n" ] && { info "Annullato."; return; }

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
        ok "Uso configurazione esistente in .devcontainer/ (nessun update richiesto)"
    fi

    echo ""
    cmd_up
}

# ── SHELL ───────────────────────────────────────────────────────────────────────
cmd_shell() {
    local cname
    cname="$(container_name)"
    container_running || err "Container '$cname' non in esecuzione. Usa: claudebox up"
    info "Apertura shell in '$cname'..."
    docker exec -it -u node "$cname" zsh
}

# ── STOP ────────────────────────────────────────────────────────────────────────
cmd_stop() {
    local cname
    cname="$(container_name)"
    container_running || { info "Container non in esecuzione."; return; }
    docker stop "$cname" >/dev/null
    ok "Container '$cname' fermato."
}

# ── DESTROY ─────────────────────────────────────────────────────────────────────
cmd_destroy() {
    local proj cname
    proj="$(project_name)"
    cname="$(container_name)"

    warn "Questa operazione rimuove container, volume history e immagine per '$proj'."
    echo  "  Il volume condiviso 'claudebox-shared-config' NON viene rimosso (condiviso tra progetti)."
    read -rp "Continuare? [y/N] " answer
    [ "${answer,,}" = "y" ] || { info "Annullato."; return; }

    container_exists && { docker rm -f "$cname" >/dev/null; ok "Container rimosso"; }
    docker volume rm "claudebox-${proj}-history" 2>/dev/null && ok "Volume history rimosso" || true
    docker rmi "claudebox-img-$proj" 2>/dev/null && ok "Immagine rimossa" || true

    echo ""
    echo "  Per rimuovere anche i volumi config condivisi:"
    echo "    docker volume rm claudebox-shared-config claudebox-shared-ccstatusline"
}

# ── HELP ────────────────────────────────────────────────────────────────────────
cmd_help() {
    cat <<HELP

  claudebox -- devcontainer Claude Code per la cartella corrente

  USO
    claudebox <comando>

  COMANDI
    install   Auto-installa lo script nel PATH (~/.local/bin)
    start     Esegue tutto in automatico: init (se serve) + build + run + claude
    init      Scarica Dockerfile e init-firewall.sh da Anthropic, genera devcontainer.json
    update    Ri-scarica Dockerfile e init-firewall.sh da Anthropic (senza toccare devcontainer.json)
    up        Build immagine, avvio container, verifica isolamento, lancia claude
    shell     Apre una shell nel container gia avviato
    stop      Ferma il container (senza rimuoverlo)
    destroy   Rimuove container, volume history e immagine

  VARIABILI D'AMBIENTE
    CLAUDE_CONFIG_DIR         Percorso della config Claude Code (default: ~/.claude)
    CCSTATUSLINE_CONFIG_DIR   Percorso config ccstatusline (default: ~/.config/ccstatusline)

  PRIMA ESECUZIONE
    # Scarica e installa (una tantum):
    bash claudebox.sh

    # Poi da qualsiasi cartella progetto -- tutto in un comando:
    cd ~/progetti/mio-progetto
    claudebox start

    # Oppure passo-passo:
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
