#!/usr/bin/env bash
# patch-dockerfile.sh -- patch project-specific per claudebox (yougo-dev)
#
# Aggiunge al Dockerfile scaricato da claudebox:
#   - PHP 8.x CLI + estensioni Symfony
#   - Composer
#   - mysql-client
# E permette di attaccare il container claudebox alla rete yougo-dev
# dello stack docker-compose (MySQL + Keycloak).
#
# USO:
#   ./patch-dockerfile.sh                  # patch del Dockerfile (idempotente)
#   ./patch-dockerfile.sh patch            # idem
#   ./patch-dockerfile.sh connect          # connetti container alla rete yougo-dev
#   ./patch-dockerfile.sh status           # mostra stato (patch/container/rete)
#
# WORKFLOW TIPICO (prima volta):
#   1) claudebox init                      # scarica Dockerfile ufficiale Anthropic
#   2) ./patch-dockerfile.sh patch         # applica le modifiche custom
#   3) docker compose up -d                # avvia MySQL + Keycloak
#   4) claudebox start -p work -y -n       # -n evita che claudebox riscarichi/aggiorni
#   5) ./patch-dockerfile.sh connect       # attacca alla rete yougo-dev
#
# ATTENZIONE: claudebox riscarica il Dockerfile ad ogni `init` e ad ogni
# `update`. Dopo quelle operazioni, ri-esegui `./patch-dockerfile.sh patch`.

set -euo pipefail

# ── Configurazione project ─────────────────────────────────────────────────────
NETWORK_NAME="yougo-dev"
DEFAULT_PROFILE="work"
DOCKERFILE=".devcontainer/Dockerfile"
MARKER_BEGIN="# >>> CLAUDEBOX_PROJECT_PATCH_YOUGO_BEGIN >>>"
MARKER_END="# <<< CLAUDEBOX_PROJECT_PATCH_YOUGO_END <<<"

# Profilo: override con env var PROFILE=... se diverso da 'work'
PROFILE="${PROFILE:-$DEFAULT_PROFILE}"

# ── Output helpers ─────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()   { echo -e "  ${CYAN}>${NC} $*"; }
ok()     { echo -e "  ${GREEN}OK${NC} $*"; }
warn()   { echo -e "  ${YELLOW}!!${NC} $*"; }
err()    { echo -e "  ${RED}ERR${NC} $*" >&2; exit 1; }

# ── Helpers (stessa logica di claudebox.sh per coerenza nei nomi) ──────────────
project_name() {
    basename "$(pwd)" \
        | tr '[:upper:]' '[:lower:]' \
        | sed 's/[^a-z0-9_-]/-/g' \
        | sed 's/-\+/-/g' \
        | sed 's/^-//;s/-$//'
}

container_name() {
    local base="claudebox-$(project_name)"
    if [ "$PROFILE" != "personal" ] && [ -n "$PROFILE" ]; then
        echo "${base}-${PROFILE}"
    else
        echo "$base"
    fi
}

# ── patch: aggiunge il blocco al Dockerfile (idempotente) ──────────────────────
cmd_patch() {
    [ -f "$DOCKERFILE" ] || err "$DOCKERFILE non trovato. Esegui prima: claudebox init"

    if grep -qF "$MARKER_BEGIN" "$DOCKERFILE"; then
        ok "Dockerfile gia' patchato (marker trovato). Niente da fare."
        info "Per riapplicare da zero: rimuovi il blocco tra '$MARKER_BEGIN' e '$MARKER_END'"
        return 0
    fi

    # Backup una tantum (non sovrascrive se esiste gia')
    if [ ! -f "${DOCKERFILE}.orig" ]; then
        cp "$DOCKERFILE" "${DOCKERFILE}.orig"
        ok "Backup salvato in ${DOCKERFILE}.orig"
    fi

    cat >> "$DOCKERFILE" <<EOF

$MARKER_BEGIN
# Aggiunte project-specific per yougo-dev:
#   - PHP 8.x CLI + estensioni richieste da Symfony
#   - Composer globale
#   - mysql-client (solo il client, il server sta nel compose)
# Applicare con: ./patch-dockerfile.sh patch
# Riapplicare dopo ogni 'claudebox init' o 'claudebox update'.

USER root

RUN apt-get update && apt-get install -y --no-install-recommends \\
        php-cli \\
        php-mbstring \\
        php-intl \\
        php-xml \\
        php-curl \\
        php-mysql \\
        php-zip \\
        php-bcmath \\
        php-gd \\
        php-sqlite3 \\
        default-mysql-client \\
        unzip \\
    && rm -rf /var/lib/apt/lists/*

# Composer (ultima versione stabile, in /usr/local/bin/composer)
RUN php -r "copy('https://getcomposer.org/installer', '/tmp/composer-setup.php');" \\
    && php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer \\
    && rm /tmp/composer-setup.php \\
    && chmod +x /usr/local/bin/composer

USER node

# Cartella cache Composer dell'utente 'node' (evita warning al primo 'composer install')
RUN mkdir -p /home/node/.composer && chown -R node:node /home/node/.composer
$MARKER_END
EOF

    ok "Dockerfile patchato."
    info "Prossimo passo: claudebox start -p $PROFILE -y -n   (il flag -n evita il pin automatico)"
    info "In alternativa: claudebox up -p $PROFILE -n"
}

# ── connect: attacca il container claudebox alla rete yougo-dev ────────────────
cmd_connect() {
    local cname; cname="$(container_name)"

    if ! docker network ls --format '{{.Name}}' 2>/dev/null | grep -qx "$NETWORK_NAME"; then
        err "Rete '$NETWORK_NAME' non esiste. Avvia prima lo stack:  docker compose up -d"
    fi

    if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$cname"; then
        err "Container '$cname' non in esecuzione. Avvialo prima:  claudebox start -p $PROFILE -y -n"
    fi

    local attached
    attached=$(docker inspect "$cname" \
        --format '{{range $k, $_ := .NetworkSettings.Networks}}{{$k}} {{end}}' 2>/dev/null || echo '')

    if echo "$attached" | grep -qw "$NETWORK_NAME"; then
        ok "Container '$cname' gia' connesso a '$NETWORK_NAME'"
    else
        docker network connect "$NETWORK_NAME" "$cname"
        ok "Connesso '$cname' a '$NETWORK_NAME'"
    fi

    echo ""
    echo "  Dal container claudebox ora raggiungi:"
    echo "    mysql:3306     (user=yougo  pwd=yougo  db=yougo_new)"
    echo "    keycloak:8080"
    echo ""
    warn "Le porte 8000 (Symfony) e 4200 (ng serve) NON sono pubblicate sull'host."
    echo "  Per raggiungerle dal browser:"
    echo "    - o modifichi claudebox.sh aggiungendo -p 8000:8000 -p 4200:4200 al docker run,"
    echo "    - o fai girare 'php -S 0.0.0.0:8000' e 'ng serve --host 0.0.0.0 --port 4200'"
    echo "      e accedi da un altro container nella stessa rete yougo-dev."
}

# ── status: stato corrente (patch / container / rete) ──────────────────────────
cmd_status() {
    local cname; cname="$(container_name)"

    echo "  Project  : $(project_name)"
    echo "  Profile  : $PROFILE"
    echo "  Container: $cname"
    echo ""

    echo -n "  Dockerfile patchato     : "
    if [ -f "$DOCKERFILE" ] && grep -qF "$MARKER_BEGIN" "$DOCKERFILE"; then
        echo -e "${GREEN}si'${NC}"
    else
        echo -e "${YELLOW}no${NC}"
    fi

    echo -n "  Rete $NETWORK_NAME esistente : "
    if docker network ls --format '{{.Name}}' 2>/dev/null | grep -qx "$NETWORK_NAME"; then
        echo -e "${GREEN}si'${NC}"
    else
        echo -e "${YELLOW}no (docker compose up -d)${NC}"
    fi

    echo -n "  Container claudebox up  : "
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$cname"; then
        echo -e "${GREEN}si'${NC}"
    else
        echo -e "${YELLOW}no${NC}"
    fi

    echo -n "  Connesso a $NETWORK_NAME  : "
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$cname"; then
        local attached
        attached=$(docker inspect "$cname" \
            --format '{{range $k, $_ := .NetworkSettings.Networks}}{{$k}} {{end}}' 2>/dev/null || echo '')
        if echo "$attached" | grep -qw "$NETWORK_NAME"; then
            echo -e "${GREEN}si'${NC}"
        else
            echo -e "${YELLOW}no (./patch-dockerfile.sh connect)${NC}"
        fi
    else
        echo "n/a"
    fi
}

cmd_help() {
    cat <<HELP

  patch-dockerfile.sh -- customizzazioni project-specific per claudebox (yougo-dev)

  USO
    ./patch-dockerfile.sh [comando]

  COMANDI
    patch     Aggiunge PHP + Composer + mysql-client al Dockerfile (default, idempotente)
    connect   Attacca il container claudebox alla rete docker 'yougo-dev'
    status    Mostra lo stato corrente (patch applicato, container, rete)
    help      Mostra questo messaggio

  VARIABILI AMBIENTE
    PROFILE   Profilo claudebox (default: $DEFAULT_PROFILE)

HELP
}

# ── Entry point ────────────────────────────────────────────────────────────────
case "${1:-patch}" in
    patch)   cmd_patch ;;
    connect) cmd_connect ;;
    status)  cmd_status ;;
    help|-h|--help) cmd_help ;;
    *) err "Comando sconosciuto: $1 (usa: patch | connect | status | help)" ;;
esac
