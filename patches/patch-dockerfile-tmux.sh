#!/usr/bin/env bash
# patch-dockerfile-tmux.sh -- aggiunge tmux al Dockerfile di claudebox
#
# USO:
#   ./patch-dockerfile-tmux.sh              # applica il patch (idempotente)
#   ./patch-dockerfile-tmux.sh patch        # idem
#   ./patch-dockerfile-tmux.sh remove       # rimuove il blocco patch
#   ./patch-dockerfile-tmux.sh status       # mostra stato corrente
#
# POSIZIONAMENTO:
#   - .devcontainer/patch-dockerfile-tmux.sh   (preferito, scoperto da claudebox)
#   - ./patch-dockerfile-tmux.sh               (project root, manuale)
#
#   Se posizionato in una di queste location, claudebox lo esegue automaticamente
#   dopo ogni 'init', 'update' e prima di ogni 'up'.
#
# COSA INSTALLA:
#   - tmux
#
# PERCHE':
#   Il gestore delle sandbox apre il terminale dal browser. Senza tmux la
#   sessione muore quando il servizio si riavvia, perche' lo stream di
#   "docker exec" muore con lui. Con tmux dentro, il server di tmux resta e la
#   sessione con lui: alla riconnessione il gestore fa "tmux attach" invece di
#   ricominciare. Il gestore rileva tmux da solo e senza si comporta bene lo
#   stesso -- dice che la sessione non sopravvivera' al riavvio, invece di
#   prometterlo.
#
# METODO:
#   apt-get, dai repository che il devcontainer Anthropic ha gia'. Nessuna
#   versione da pinnare: tmux e' un pacchetto Debian stabile e un attach che
#   funziona funziona in tutte le versioni che Debian spedisce. Aggiunge
#   ~1 MB all'immagine.
#
# VARIABILI AMBIENTE:
#   DOCKERFILE     Path al Dockerfile (override auto-discovery)

set -euo pipefail

# ── Configurazione ─────────────────────────────────────────────────────────────
MARKER_BEGIN="# >>> CLAUDEBOX_PATCH_TMUX_BEGIN >>>"
MARKER_END="# <<< CLAUDEBOX_PATCH_TMUX_END <<<"

# ── Output helpers ─────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "  ${CYAN}>${NC} $*"; }
ok()   { echo -e "  ${GREEN}OK${NC} $*"; }
warn() { echo -e "  ${YELLOW}!!${NC} $*"; }
err()  { echo -e "  ${RED}ERR${NC} $*" >&2; exit 1; }

# ── Dockerfile discovery ───────────────────────────────────────────────────────
find_dockerfile() {
    local candidates=(
        "${DOCKERFILE:-}"              # override esplicito via env var
        "Dockerfile"                   # cwd diretto (.devcontainer/ o custom)
        ".devcontainer/Dockerfile"     # project root
    )
    local c
    for c in "${candidates[@]}"; do
        [ -z "$c" ] && continue
        if [ -f "$c" ]; then
            printf '%s' "$c"
            return 0
        fi
    done
    return 1
}

DOCKERFILE="$(find_dockerfile || true)"

# ── patch ──────────────────────────────────────────────────────────────────────
cmd_patch() {
    [ -n "$DOCKERFILE" ] || err "Dockerfile non trovato (cercato in ./Dockerfile e ./.devcontainer/Dockerfile). Esegui prima: claudebox init"

    if grep -qF "$MARKER_BEGIN" "$DOCKERFILE"; then
        ok "Patch tmux gia' presente in $DOCKERFILE. Niente da fare."
        return 0
    fi

    # Backup una tantum (non sovrascrive se esiste gia')
    if [ ! -f "${DOCKERFILE}.orig" ]; then
        cp "$DOCKERFILE" "${DOCKERFILE}.orig"
        ok "Backup in ${DOCKERFILE}.orig"
    fi

    cat >> "$DOCKERFILE" <<EOF

$MARKER_BEGIN
# tmux
# Aggiunto da patch-dockerfile-tmux.sh -- riapplicato automaticamente da claudebox.
# Serve al terminale nel browser: il server di tmux resta in piedi quando lo
# stream di "docker exec" muore, cosi' la sessione sopravvive al riavvio del
# gestore e alla riconnessione ci si riattacca invece di ricominciare.

USER root

# 1. tmux dai repository Debian gia' configurati nell'immagine.
#    Niente versione pinnata: il pacchetto stabile basta, e un repository in
#    piu' sarebbe un pezzo in piu' che si rompe per niente.
RUN apt-get update && apt-get install -y --no-install-recommends tmux \\
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# 2. Smoke test: fallisce la build se tmux non e' nel PATH.
#    "command -v tmux" e' la stessa domanda che il gestore fara' a runtime per
#    decidere se promettere che la sessione sopravvive.
RUN command -v tmux && tmux -V

USER node
$MARKER_END
EOF

    ok "Dockerfile patchato ($DOCKERFILE): tmux."
}

# ── remove ─────────────────────────────────────────────────────────────────────
cmd_remove() {
    [ -n "$DOCKERFILE" ] || err "Dockerfile non trovato."

    if ! grep -qF "$MARKER_BEGIN" "$DOCKERFILE"; then
        ok "Nessun patch tmux trovato in $DOCKERFILE. Niente da rimuovere."
        return 0
    fi

    # Rimuove tutto tra i marker. sed -i ha sintassi diversa su GNU vs BSD (macOS).
    if sed --version 2>/dev/null | grep -q GNU; then
        sed -i "/^${MARKER_BEGIN}$/,/^${MARKER_END}$/d" "$DOCKERFILE"
    else
        sed -i '' "/^${MARKER_BEGIN}$/,/^${MARKER_END}$/d" "$DOCKERFILE"
    fi

    ok "Blocco patch tmux rimosso da $DOCKERFILE."
}

# ── status ─────────────────────────────────────────────────────────────────────
cmd_status() {
    echo ""
    echo -n "  Dockerfile trovato   : "
    if [ -n "$DOCKERFILE" ]; then
        echo -e "${GREEN}si'${NC}  ($DOCKERFILE)"
    else
        echo -e "${YELLOW}no${NC}  (claudebox init non ancora eseguito)"
        echo ""
        return
    fi

    echo -n "  Patch tmux applicato : "
    if grep -qF "$MARKER_BEGIN" "$DOCKERFILE"; then
        echo -e "${GREEN}si'${NC}  (tmux dai repository Debian)"
    else
        echo -e "${YELLOW}no${NC}  (./patch-dockerfile-tmux.sh patch)"
    fi

    echo -n "  Backup orig presente : "
    if [ -f "${DOCKERFILE}.orig" ]; then
        echo -e "${GREEN}si'${NC}  (${DOCKERFILE}.orig)"
    else
        echo -e "${YELLOW}no${NC}"
    fi
    echo ""
}

# ── help ───────────────────────────────────────────────────────────────────────
cmd_help() {
    cat <<HELP

  patch-dockerfile-tmux.sh -- aggiunge tmux al Dockerfile claudebox

  USO
    ./patch-dockerfile-tmux.sh [comando]

  COMANDI
    patch    Aggiunge tmux (default, idempotente)
    remove   Rimuove il blocco patch
    status   Mostra lo stato corrente
    help     Mostra questo messaggio

  POSIZIONAMENTO CONSIGLIATO
    .devcontainer/patch-dockerfile-tmux.sh
    -> claudebox lo esegue automaticamente dopo init/update e prima di up.

  VARIABILI AMBIENTE
    DOCKERFILE   Path al Dockerfile da patchare (override auto-discovery)

  WORKFLOW AUTOMATICO
    cp patch-dockerfile-tmux.sh .devcontainer/
    claudebox start -y

  COSA OTTIENI NEL CONTAINER
    tmux       Il terminale che il gestore apre dal browser gira dentro una
               sessione di tmux, e la sessione resta anche quando il gestore si
               riavvia: alla riconnessione ci si riattacca invece di
               ricominciare. Su un container senza tmux il terminale funziona
               lo stesso, ma la pagina dichiara che la sessione non
               sopravvivera' al riavvio.

HELP
}

# ── Entry point ────────────────────────────────────────────────────────────────
case "${1:-patch}" in
    patch)   cmd_patch  ;;
    remove)  cmd_remove ;;
    status)  cmd_status ;;
    help|-h|--help) cmd_help ;;
    *) err "Comando sconosciuto: $1  (usa: patch | remove | status | help)" ;;
esac
