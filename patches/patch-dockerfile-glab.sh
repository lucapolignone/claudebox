#!/usr/bin/env bash
# patch-dockerfile-glab.sh -- aggiunge la CLI glab (GitLab) al Dockerfile claudebox
#
# USO:
#   ./patch-dockerfile-glab.sh              # applica (idempotente)
#   ./patch-dockerfile-glab.sh patch        # idem
#   ./patch-dockerfile-glab.sh remove       # rimuove il blocco
#   ./patch-dockerfile-glab.sh status       # stato corrente
#
# POSIZIONAMENTO:
#   - .devcontainer/patch-dockerfile-glab.sh   (preferito)
#   - ./patch-dockerfile-glab.sh               (project root)
#
# COSA INSTALLA:
#   - /usr/local/bin/glab (GitLab CLI, https://gitlab.com/gitlab-org/cli)
#
# METODO:
#   Scarica il tarball release ufficiale (linux_x86_64 o linux_arm64) dalla
#   pagina releases del progetto e installa il binario in /usr/local/bin.
#
# VARIABILI AMBIENTE:
#   GLAB_VERSION   Versione di glab da installare (default: 1.49.0)
#                  Es: '1.49.0', '1.50.0'
#                  Pinna a una versione specifica per build riproducibili.
#   DOCKERFILE     Path al Dockerfile (override auto-discovery)

set -euo pipefail

# ── Configurazione ─────────────────────────────────────────────────────────────
GLAB_VERSION="${GLAB_VERSION:-1.49.0}"
MARKER_BEGIN="# >>> CLAUDEBOX_PATCH_GLAB_BEGIN >>>"
MARKER_END="# <<< CLAUDEBOX_PATCH_GLAB_END <<<"

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
        "${DOCKERFILE:-}"
        "Dockerfile"
        ".devcontainer/Dockerfile"
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
        ok "Patch glab gia' presente in $DOCKERFILE. Niente da fare."
        return 0
    fi

    if [ ! -f "${DOCKERFILE}.orig" ]; then
        cp "$DOCKERFILE" "${DOCKERFILE}.orig"
        ok "Backup in ${DOCKERFILE}.orig"
    fi

    cat >> "$DOCKERFILE" <<EOF

$MARKER_BEGIN
# GitLab CLI 'glab' v${GLAB_VERSION}
# Aggiunto da patch-dockerfile-glab.sh -- riapplicato automaticamente da claudebox.
# Metodo: download binario dal release ufficiale (GitLab Releases) e install in
# /usr/local/bin. Funziona su amd64 e arm64.

USER root

ARG GLAB_VERSION=${GLAB_VERSION}
RUN set -eux; \\
    arch="\$(dpkg --print-architecture)"; \\
    case "\$arch" in \\
        amd64) glab_arch="amd64" ;; \\
        arm64) glab_arch="arm64" ;; \\
        *) echo "unsupported arch: \$arch" >&2; exit 1 ;; \\
    esac; \\
    curl -fsSL -o /tmp/glab.tgz \\
        "https://gitlab.com/gitlab-org/cli/-/releases/v\${GLAB_VERSION}/downloads/glab_\${GLAB_VERSION}_linux_\${glab_arch}.tar.gz"; \\
    tar -xzf /tmp/glab.tgz -C /tmp; \\
    install -m 0755 /tmp/bin/glab /usr/local/bin/glab; \\
    rm -rf /tmp/glab.tgz /tmp/bin /tmp/LICENSE /tmp/README.md 2>/dev/null || true; \\
    glab --version

USER node
$MARKER_END
EOF

    ok "Dockerfile patchato ($DOCKERFILE): glab v${GLAB_VERSION}."
}

# ── remove ─────────────────────────────────────────────────────────────────────
cmd_remove() {
    [ -n "$DOCKERFILE" ] || err "Dockerfile non trovato."

    if ! grep -qF "$MARKER_BEGIN" "$DOCKERFILE"; then
        ok "Nessun patch glab trovato in $DOCKERFILE. Niente da rimuovere."
        return 0
    fi

    if sed --version 2>/dev/null | grep -q GNU; then
        sed -i "/^${MARKER_BEGIN}$/,/^${MARKER_END}$/d" "$DOCKERFILE"
    else
        sed -i '' "/^${MARKER_BEGIN}$/,/^${MARKER_END}$/d" "$DOCKERFILE"
    fi

    ok "Blocco patch glab rimosso da $DOCKERFILE."
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

    echo -n "  Patch glab applicato : "
    if grep -qF "$MARKER_BEGIN" "$DOCKERFILE"; then
        local ver
        ver=$(grep -oE 'ARG GLAB_VERSION=[a-zA-Z0-9._-]+' "$DOCKERFILE" | head -1 | cut -d= -f2 || echo "?")
        echo -e "${GREEN}si'${NC}  (glab $ver)"
    else
        echo -e "${YELLOW}no${NC}  (./patch-dockerfile-glab.sh patch)"
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

  patch-dockerfile-glab.sh -- aggiunge la CLI glab al Dockerfile claudebox

  USO
    ./patch-dockerfile-glab.sh [comando]

  COMANDI
    patch    Aggiunge glab (default, idempotente)
    remove   Rimuove il blocco patch
    status   Mostra lo stato corrente
    help     Mostra questo messaggio

  POSIZIONAMENTO CONSIGLIATO
    .devcontainer/patch-dockerfile-glab.sh
    -> claudebox lo esegue automaticamente dopo init/update e prima di up.

  VARIABILI AMBIENTE
    GLAB_VERSION   Versione glab (default: 1.49.0)
                   Pinna a una versione specifica per build riproducibili.
    DOCKERFILE     Path al Dockerfile (override auto-discovery)

  COSA OTTIENI NEL CONTAINER
    glab           CLI ufficiale GitLab (clone, MR, issue, CI, ecc.)
                   Es: glab mr list
                       glab issue create
                       glab ci view

  AUTENTICAZIONE
    Per autenticare glab nel container, claudebox puo' iniettare le credenziali
    GitLab dell'host (\$GITLAB_TOKEN env var + ~/.config/glab-cli/ in RO).
    L'opt-in viene chiesto a 'claudebox init' o 'claudebox start'.

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
