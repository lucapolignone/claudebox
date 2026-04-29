#!/usr/bin/env bash
# patch-dockerfile-uvx.sh -- aggiunge uv + uvx (Astral) al Dockerfile di claudebox
#
# USO:
#   ./patch-dockerfile-uvx.sh              # applica il patch (idempotente)
#   ./patch-dockerfile-uvx.sh patch        # idem
#   ./patch-dockerfile-uvx.sh remove       # rimuove il blocco patch
#   ./patch-dockerfile-uvx.sh status       # mostra stato corrente
#
# POSIZIONAMENTO:
#   - .devcontainer/patch-dockerfile-uvx.sh   (preferito, scoperto da claudebox)
#   - ./patch-dockerfile-uvx.sh               (project root, manuale)
#
#   Se posizionato in una di queste location, claudebox lo esegue automaticamente
#   dopo ogni 'init', 'update' e prima di ogni 'up'.
#
# COSA INSTALLA:
#   - uv  (Python package manager / project manager)
#   - uvx (alias di 'uv tool run', esegue tool Python in env effimero)
#
# METODO:
#   Copia i binari dall'immagine ufficiale distroless ghcr.io/astral-sh/uv:<ver>
#   in /usr/local/bin (sempre nel PATH). Vantaggi vs standalone installer:
#     - molto piu' veloce (no curl + sh)
#     - pinning di versione esplicito e riproducibile
#     - nessun layer apt aggiuntivo
#     - i binari sono statici (musl), niente dipendenze runtime

set -euo pipefail

# ── Configurazione ─────────────────────────────────────────────────────────────
# Override con env var: UV_VERSION=0.5.0 ./patch-dockerfile-uvx.sh patch
UV_VERSION="${UV_VERSION:-latest}"
MARKER_BEGIN="# >>> CLAUDEBOX_PATCH_UVX_BEGIN >>>"
MARKER_END="# <<< CLAUDEBOX_PATCH_UVX_END <<<"

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
        ok "Patch uvx gia' presente in $DOCKERFILE. Niente da fare."
        return 0
    fi

    # Backup una tantum (non sovrascrive se esiste gia')
    if [ ! -f "${DOCKERFILE}.orig" ]; then
        cp "$DOCKERFILE" "${DOCKERFILE}.orig"
        ok "Backup in ${DOCKERFILE}.orig"
    fi

    cat >> "$DOCKERFILE" <<EOF

$MARKER_BEGIN
# uv + uvx (Astral) v${UV_VERSION}
# Aggiunto da patch-dockerfile-uvx.sh -- riapplicato automaticamente da claudebox.
# Metodo: COPY dei binari dall'immagine ufficiale distroless (raccomandato dalla
# documentazione ufficiale uv https://docs.astral.sh/uv/guides/integration/docker/).

USER root

# 1. Copia i binari uv e uvx dall'immagine ufficiale in /usr/local/bin
#    /usr/local/bin e' sempre nel PATH standard, niente ENV PATH override necessari.
COPY --from=ghcr.io/astral-sh/uv:${UV_VERSION} /uv /uvx /usr/local/bin/

# 2. UV_TOOL_BIN_DIR: directory dove finiscono i binari di 'uv tool install <pkg>'
#    Settando a /usr/local/bin, i tool installati con 'uv tool install' sono
#    immediatamente disponibili nel PATH per tutti gli utenti.
ENV UV_TOOL_BIN_DIR=/usr/local/bin

# 3. UV_LINK_MODE=copy: silenzia i warning sui link cross-filesystem quando
#    il devcontainer monta volumi separati per cache e workspace.
ENV UV_LINK_MODE=copy

# 4. Smoke test: fallisce la build se i binari non sono raggiungibili
RUN uv --version && uvx --version && which uv && which uvx

USER node
$MARKER_END
EOF

    ok "Dockerfile patchato ($DOCKERFILE): uv + uvx (v${UV_VERSION})."
}

# ── remove ─────────────────────────────────────────────────────────────────────
cmd_remove() {
    [ -n "$DOCKERFILE" ] || err "Dockerfile non trovato."

    if ! grep -qF "$MARKER_BEGIN" "$DOCKERFILE"; then
        ok "Nessun patch uvx trovato in $DOCKERFILE. Niente da rimuovere."
        return 0
    fi

    # Rimuove tutto tra i marker. sed -i ha sintassi diversa su GNU vs BSD (macOS).
    if sed --version 2>/dev/null | grep -q GNU; then
        sed -i "/^${MARKER_BEGIN}$/,/^${MARKER_END}$/d" "$DOCKERFILE"
    else
        sed -i '' "/^${MARKER_BEGIN}$/,/^${MARKER_END}$/d" "$DOCKERFILE"
    fi

    ok "Blocco patch uvx rimosso da $DOCKERFILE."
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

    echo -n "  Patch uvx applicato  : "
    if grep -qF "$MARKER_BEGIN" "$DOCKERFILE"; then
        local ver
        ver=$(grep -oE 'astral-sh/uv:[a-zA-Z0-9._-]+' "$DOCKERFILE" | head -1 | cut -d: -f2 || echo "?")
        echo -e "${GREEN}si'${NC}  (uv $ver)"
    else
        echo -e "${YELLOW}no${NC}  (./patch-dockerfile-uvx.sh patch)"
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

  patch-dockerfile-uvx.sh -- aggiunge uv + uvx al Dockerfile claudebox

  USO
    ./patch-dockerfile-uvx.sh [comando]

  COMANDI
    patch    Aggiunge uv + uvx (default, idempotente)
    remove   Rimuove il blocco patch
    status   Mostra lo stato corrente
    help     Mostra questo messaggio

  POSIZIONAMENTO CONSIGLIATO
    .devcontainer/patch-dockerfile-uvx.sh
    -> claudebox lo esegue automaticamente dopo init/update e prima di up.

  VARIABILI AMBIENTE
    UV_VERSION   Versione uv da installare (default: latest)
                 Es: 'latest', '0.11.8', '0.5'
                 Pinna a una versione specifica per builds riproducibili.
    DOCKERFILE   Path al Dockerfile da patchare (override auto-discovery)

  WORKFLOW AUTOMATICO
    cp patch-dockerfile-uvx.sh .devcontainer/
    claudebox start -y

  COSA OTTIENI NEL CONTAINER
    uv         Python package manager (pip, venv, project, lock, ecc.)
    uvx        Alias di 'uv tool run' -- esegue tool Python in env effimero
               Es: uvx ruff check .   (esegue ruff senza installarlo)
                   uvx black .        (esegue black senza installarlo)
                   uvx pytest         (esegue pytest senza installarlo)

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
