#!/usr/bin/env bash
# patch-dockerfile-playwright.sh -- aggiunge Playwright (Node) + browser headless al Dockerfile claudebox
#
# USO:
#   ./patch-dockerfile-playwright.sh              # applica il patch (idempotente)
#   ./patch-dockerfile-playwright.sh patch        # idem
#   ./patch-dockerfile-playwright.sh remove       # rimuove il blocco patch
#   ./patch-dockerfile-playwright.sh status       # mostra stato corrente
#
# POSIZIONAMENTO:
#   - .devcontainer/patch-dockerfile-playwright.sh   (preferito, scoperto da claudebox)
#   - ./patch-dockerfile-playwright.sh               (project root, manuale)
#
#   Se posizionato in una di queste location, claudebox lo esegue automaticamente
#   dopo ogni 'init', 'update' e prima di ogni 'up'.
#
# COSA INSTALLA:
#   - @playwright/test (CLI Playwright, install globale via npm)
#   - Tutti i browser supportati: chromium, firefox, webkit
#   - Tutte le dipendenze apt di sistema (libnss3, libgbm, fonts, ...)
#
# METODO:
#   1) npm install -g @playwright/test@<ver>
#   2) PLAYWRIGHT_BROWSERS_PATH=/ms-playwright (cache system-wide condivisa)
#   3) npx playwright install --with-deps  (browser + apt deps in un solo RUN)
#
#   Convenzione ufficiale Playwright per Docker. Aggiunge ~700 MB all'immagine.

set -euo pipefail

# ── Configurazione ─────────────────────────────────────────────────────────────
# Override con env var: PLAYWRIGHT_VERSION=1.49.0 ./patch-dockerfile-playwright.sh patch
PLAYWRIGHT_VERSION="${PLAYWRIGHT_VERSION:-latest}"
MARKER_BEGIN="# >>> CLAUDEBOX_PATCH_PLAYWRIGHT_BEGIN >>>"
MARKER_END="# <<< CLAUDEBOX_PATCH_PLAYWRIGHT_END <<<"

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
        ok "Patch playwright gia' presente in $DOCKERFILE. Niente da fare."
        return 0
    fi

    # Backup una tantum (non sovrascrive se esiste gia')
    if [ ! -f "${DOCKERFILE}.orig" ]; then
        cp "$DOCKERFILE" "${DOCKERFILE}.orig"
        ok "Backup in ${DOCKERFILE}.orig"
    fi

    cat >> "$DOCKERFILE" <<EOF

$MARKER_BEGIN
# Playwright (Node) v${PLAYWRIGHT_VERSION} + tutti i browser + apt deps
# Aggiunto da patch-dockerfile-playwright.sh -- riapplicato automaticamente da claudebox.
# Cache browser system-wide: convenzione ufficiale Playwright per Docker
# (https://playwright.dev/docs/docker).

USER root

# 1. Cache browser system-wide -- un solo download condiviso fra root e node.
ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright

# 2. CLI @playwright/test globale (npm e' gia' nel devcontainer Anthropic).
RUN npm install -g @playwright/test@${PLAYWRIGHT_VERSION}

# 3. Tutti i browser (chromium+firefox+webkit, default senza argomenti) + apt deps
#    in un solo RUN. --with-deps esegue apt-get update + install dei pacchetti
#    Debian richiesti dai browser (libnss3, libgbm, fonts, ecc.).
RUN npx playwright install --with-deps

# 4. Permessi RO + execute per utente non-root sul cache dir
RUN chmod -R a+rx /ms-playwright

# 5. Smoke test: fallisce la build se l'install e' rotto
RUN npx playwright --version

USER node
$MARKER_END
EOF

    ok "Dockerfile patchato ($DOCKERFILE): Playwright + browser (v${PLAYWRIGHT_VERSION})."
}

# ── remove ─────────────────────────────────────────────────────────────────────
cmd_remove() {
    [ -n "$DOCKERFILE" ] || err "Dockerfile non trovato."

    if ! grep -qF "$MARKER_BEGIN" "$DOCKERFILE"; then
        ok "Nessun patch playwright trovato in $DOCKERFILE. Niente da rimuovere."
        return 0
    fi

    # Rimuove tutto tra i marker. sed -i ha sintassi diversa su GNU vs BSD (macOS).
    if sed --version 2>/dev/null | grep -q GNU; then
        sed -i "/^${MARKER_BEGIN}$/,/^${MARKER_END}$/d" "$DOCKERFILE"
    else
        sed -i '' "/^${MARKER_BEGIN}$/,/^${MARKER_END}$/d" "$DOCKERFILE"
    fi

    ok "Blocco patch playwright rimosso da $DOCKERFILE."
}

# ── status ─────────────────────────────────────────────────────────────────────
cmd_status() {
    echo ""
    echo -n "  Dockerfile trovato         : "
    if [ -n "$DOCKERFILE" ]; then
        echo -e "${GREEN}si'${NC}  ($DOCKERFILE)"
    else
        echo -e "${YELLOW}no${NC}  (claudebox init non ancora eseguito)"
        echo ""
        return
    fi

    echo -n "  Patch playwright applicato : "
    if grep -qF "$MARKER_BEGIN" "$DOCKERFILE"; then
        local ver
        ver=$(grep -oE '@playwright/test@[a-zA-Z0-9._-]+' "$DOCKERFILE" | head -1 | cut -d@ -f3 || echo "?")
        echo -e "${GREEN}si'${NC}  (@playwright/test $ver)"
    else
        echo -e "${YELLOW}no${NC}  (./patch-dockerfile-playwright.sh patch)"
    fi

    echo -n "  Backup orig presente       : "
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

  patch-dockerfile-playwright.sh -- aggiunge Playwright (Node) + browser al Dockerfile claudebox

  USO
    ./patch-dockerfile-playwright.sh [comando]

  COMANDI
    patch    Aggiunge Playwright + browser (default, idempotente)
    remove   Rimuove il blocco patch
    status   Mostra lo stato corrente
    help     Mostra questo messaggio

  POSIZIONAMENTO CONSIGLIATO
    .devcontainer/patch-dockerfile-playwright.sh
    -> claudebox lo esegue automaticamente dopo init/update e prima di up.

  VARIABILI AMBIENTE
    PLAYWRIGHT_VERSION  Versione di @playwright/test (default: latest)
                        Es: 'latest', '1.49.0', '1.48'
                        Pinna per builds riproducibili.
    DOCKERFILE          Path al Dockerfile (override auto-discovery)

  WORKFLOW AUTOMATICO
    cp patch-dockerfile-playwright.sh .devcontainer/
    claudebox start -y

  COSA OTTIENI NEL CONTAINER
    @playwright/test    CLI Playwright (npx playwright test, codegen, show-report, ...)
    /ms-playwright/     Cache system-wide con chromium, firefox, webkit
    apt deps            libnss3, libgbm, fonts, ecc. (necessarie ai browser)

  NOTA DIMENSIONI
    Aggiunge ~700 MB all'immagine finale (browser + apt deps).

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
