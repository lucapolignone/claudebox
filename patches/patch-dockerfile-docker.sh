#!/usr/bin/env bash
# patch-dockerfile-docker.sh -- aggiunge Docker CLI + Buildx + Compose v2 al
# Dockerfile di claudebox (Docker-outside-of-Docker, niente daemon dentro).
#
# USO:
#   ./patch-dockerfile-docker.sh              # applica il patch (idempotente)
#   ./patch-dockerfile-docker.sh patch        # idem
#   ./patch-dockerfile-docker.sh remove       # rimuove il blocco patch
#   ./patch-dockerfile-docker.sh status       # mostra stato corrente
#
# POSIZIONAMENTO:
#   - .devcontainer/patch-dockerfile-docker.sh   (preferito, scoperto da claudebox)
#   - ./patch-dockerfile-docker.sh               (project root, manuale)
#
#   In una di queste location claudebox lo esegue automaticamente dopo ogni
#   'init', 'update' e prima di ogni 'up'.
#
# COSA INSTALLA:
#   - docker-ce-cli           Docker client (comandi `docker`, `docker run`, ecc.)
#   - docker-buildx-plugin    Build moderno (BuildKit, multi-arch, cache export)
#   - docker-compose-plugin   `docker compose` v2 (plugin, niente standalone)
#
#   NON installa il daemon (`dockerd`). Il modello e' Docker-outside-of-Docker:
#   il container parla al docker del tuo HOST tramite il socket Unix.
#
# REQUISITO RUNTIME (importante!):
#   Il socket dell'host va montato dentro al container:
#       -v /var/run/docker.sock:/var/run/docker.sock
#
#   Senza il bind mount, qualsiasi comando docker fallira' con:
#       Cannot connect to the Docker daemon at unix:///var/run/docker.sock
#
#   Su macOS/Windows con Docker Desktop il socket esiste comunque a quel path.
#   Su Linux il GID del gruppo `docker` dell'host puo' non matchare quello dentro
#   il container: in tal caso `chmod 666 /var/run/docker.sock` lato host (NON in
#   produzione) o allinea i GID con un'opzione runtime tipo --group-add.
#
# METODO:
#   Installazione dal repository ufficiale download.docker.com con keyring
#   gpg dearmored (formato che apt si aspetta con `signed-by=`). Auto-detect
#   della distro (ubuntu vs debian) e del codename via /etc/os-release, stessa
#   tecnica del patch java. Multi-arch via $(dpkg --print-architecture).

set -euo pipefail

# ── Configurazione ─────────────────────────────────────────────────────────────
# Override con env var: DOCKER_CHANNEL=test ./patch-dockerfile-docker.sh patch
DOCKER_CHANNEL="${DOCKER_CHANNEL:-stable}"
MARKER_BEGIN="# >>> CLAUDEBOX_PATCH_DOCKER_BEGIN >>>"
MARKER_END="# <<< CLAUDEBOX_PATCH_DOCKER_END <<<"

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
        ok "Patch docker gia' presente in $DOCKERFILE. Niente da fare."
        return 0
    fi

    # Backup una tantum (non sovrascrive se esiste gia')
    if [ ! -f "${DOCKERFILE}.orig" ]; then
        cp "$DOCKERFILE" "${DOCKERFILE}.orig"
        ok "Backup in ${DOCKERFILE}.orig"
    fi

    cat >> "$DOCKERFILE" <<EOF

$MARKER_BEGIN
# Docker CLI + Buildx + Compose v2 (Docker-outside-of-Docker)
# Aggiunto da patch-dockerfile-docker.sh -- riapplicato automaticamente da claudebox.
#
# Modello: il container NON ha un daemon dockerd proprio. Parla al docker
# dell'HOST via socket Unix. A runtime serve:
#   -v /var/run/docker.sock:/var/run/docker.sock

USER root

# 1. Repo ufficiale Docker (cross-distro: rileva ubuntu vs debian dal codename)
RUN apt-get update && apt-get install -y --no-install-recommends \\
        ca-certificates curl gnupg \\
    && install -m 0755 -d /etc/apt/keyrings \\
    && . /etc/os-release \\
    && DOCKER_DISTRO=\$( [ "\$ID" = "ubuntu" ] && echo ubuntu || echo debian ) \\
    && curl -fsSL "https://download.docker.com/linux/\${DOCKER_DISTRO}/gpg" \\
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg \\
    && chmod a+r /etc/apt/keyrings/docker.gpg \\
    && echo "deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/\${DOCKER_DISTRO} \${VERSION_CODENAME} ${DOCKER_CHANNEL}" \\
        > /etc/apt/sources.list.d/docker.list \\
    && apt-get update \\
    && apt-get install -y --no-install-recommends \\
        docker-ce-cli \\
        docker-buildx-plugin \\
        docker-compose-plugin \\
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# 2. Aggiungi 'node' al gruppo docker per parlare al socket senza sudo.
#    Il pacchetto docker-ce-cli NON crea il gruppo (lo fa docker-ce, che non
#    installiamo), quindi lo creiamo a mano. Il GID e' arbitrario; al runtime
#    potrebbe non matchare il GID del docker.sock dell'host (vedi note in cima).
RUN groupadd -f docker && usermod -aG docker node

USER node
$MARKER_END
EOF

    ok "Dockerfile patchato ($DOCKERFILE): docker CLI + buildx + compose ($DOCKER_CHANNEL)."
    info "Ricorda di montare il socket a runtime: -v /var/run/docker.sock:/var/run/docker.sock"
}

# ── remove ─────────────────────────────────────────────────────────────────────
cmd_remove() {
    [ -n "$DOCKERFILE" ] || err "Dockerfile non trovato."

    if ! grep -qF "$MARKER_BEGIN" "$DOCKERFILE"; then
        ok "Nessun patch docker trovato in $DOCKERFILE. Niente da rimuovere."
        return 0
    fi

    # Rimuove tutto tra i marker. sed -i ha sintassi diversa su GNU vs BSD (macOS).
    if sed --version 2>/dev/null | grep -q GNU; then
        sed -i "/^${MARKER_BEGIN}$/,/^${MARKER_END}$/d" "$DOCKERFILE"
    else
        sed -i '' "/^${MARKER_BEGIN}$/,/^${MARKER_END}$/d" "$DOCKERFILE"
    fi

    ok "Blocco patch docker rimosso da $DOCKERFILE."
}

# ── status ─────────────────────────────────────────────────────────────────────
cmd_status() {
    echo ""
    echo -n "  Dockerfile trovato     : "
    if [ -n "$DOCKERFILE" ]; then
        echo -e "${GREEN}si'${NC}  ($DOCKERFILE)"
    else
        echo -e "${YELLOW}no${NC}   (claudebox init non ancora eseguito)"
        echo ""
        return
    fi

    echo -n "  Patch docker applicato : "
    if grep -qF "$MARKER_BEGIN" "$DOCKERFILE"; then
        local ch
        ch=$(grep -oE 'download\.docker\.com/linux/[a-z]+ [a-z]+ [a-z]+' "$DOCKERFILE" | head -1 | awk '{print $3}' || echo "?")
        echo -e "${GREEN}si'${NC}  (channel: ${ch:-?})"
    else
        echo -e "${YELLOW}no${NC}   (./patch-dockerfile-docker.sh patch)"
    fi

    echo -n "  Backup orig presente   : "
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

  patch-dockerfile-docker.sh -- aggiunge Docker CLI + Buildx + Compose v2

  USO
    ./patch-dockerfile-docker.sh [comando]

  COMANDI
    patch    Aggiunge Docker CLI + buildx + compose plugin (default, idempotente)
    remove   Rimuove il blocco patch
    status   Mostra lo stato corrente
    help     Mostra questo messaggio

  POSIZIONAMENTO CONSIGLIATO
    .devcontainer/patch-dockerfile-docker.sh
    -> claudebox lo esegue automaticamente dopo init/update e prima di up.

  VARIABILI AMBIENTE
    DOCKER_CHANNEL   Canale apt Docker: 'stable' (default), 'test'
    DOCKERFILE       Path al Dockerfile (override auto-discovery)

  WORKFLOW AUTOMATICO
    cp patch-dockerfile-docker.sh .devcontainer/
    claudebox start -y

  REQUISITO RUNTIME
    Il container deve montare il socket dell'host:
      -v /var/run/docker.sock:/var/run/docker.sock

    Se claudebox non lo monta automaticamente, modifica claudebox.sh aggiungendo
    questo bind mount nei DOCKER_RUN_OPTS, oppure usa 'docker exec' a mano.

  NOTE GID (Linux)
    Il GID del gruppo 'docker' dentro il container quasi certamente NON matcha
    quello del docker.sock dell'host. Workaround:
      - macOS/Windows: nessun problema, Docker Desktop espone il socket world-rw.
      - Linux dev: chmod 666 /var/run/docker.sock (NON in produzione)
                   oppure --group-add \$(stat -c '%g' /var/run/docker.sock)

  COSA OTTIENI NEL CONTAINER
    docker             Client (run, ps, build, push, ...)
    docker buildx      Build moderno multi-arch con BuildKit
    docker compose     Compose v2 (plugin, NON 'docker-compose' v1)

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
