#!/usr/bin/env bash
# patch-dockerfile-java.sh -- aggiunge Java 21 + Maven al Dockerfile di claudebox
#
# USO:
#   ./patch-dockerfile-java.sh              # applica il patch (idempotente)
#   ./patch-dockerfile-java.sh patch        # idem
#   ./patch-dockerfile-java.sh remove       # rimuove il blocco patch
#   ./patch-dockerfile-java.sh status       # mostra stato corrente
#
# POSIZIONAMENTO:
#   Metti questo file in UNA di queste posizioni:
#     - .devcontainer/patch-dockerfile-java.sh   (preferito, scoperto da claudebox)
#     - ./patch-dockerfile-java.sh               (project root, manuale)
#
#   Se posizionato in .devcontainer/, claudebox lo esegue AUTOMATICAMENTE
#   dopo ogni 'init' e 'update', e anche prima di ogni 'up' come safety net.
#   Niente piu' patch che spariscono dopo un update.
#
# WORKFLOW TIPICO (automatico):
#   1) cp patch-dockerfile-java.sh .devcontainer/
#   2) claudebox start -y        # init + patch auto + build + run
#
# WORKFLOW MANUALE:
#   1) claudebox init
#   2) ./patch-dockerfile-java.sh patch
#   3) claudebox start -y -n

set -euo pipefail

# ── Configurazione ─────────────────────────────────────────────────────────────
MAVEN_VERSION="${MAVEN_VERSION:-3.9.9}"
MARKER_BEGIN="# >>> CLAUDEBOX_PATCH_JAVA_BEGIN >>>"
MARKER_END="# <<< CLAUDEBOX_PATCH_JAVA_END <<<"

# ── Output helpers ─────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "  ${CYAN}>${NC} $*"; }
ok()   { echo -e "  ${GREEN}OK${NC} $*"; }
warn() { echo -e "  ${YELLOW}!!${NC} $*"; }
err()  { echo -e "  ${RED}ERR${NC} $*" >&2; exit 1; }

# ── Dockerfile discovery ───────────────────────────────────────────────────────
# Il patch script puo' essere eseguito da 3 contesti diversi:
#   a) da claudebox.sh (cwd=.devcontainer/)         -> ./Dockerfile
#   b) dall'utente in project root                   -> ./.devcontainer/Dockerfile
#   c) dall'utente in .devcontainer/                 -> ./Dockerfile
# Trova il primo esistente; se nessuno esiste, errore esplicito.
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
        ok "Patch Java gia' presente in $DOCKERFILE. Niente da fare."
        return 0
    fi

    # Backup una tantum (non sovrascrive se esiste gia')
    if [ ! -f "${DOCKERFILE}.orig" ]; then
        cp "$DOCKERFILE" "${DOCKERFILE}.orig"
        ok "Backup in ${DOCKERFILE}.orig"
    fi

    cat >> "$DOCKERFILE" <<EOF

$MARKER_BEGIN
# Java 21 (Eclipse Temurin) + Maven ${MAVEN_VERSION}
# Aggiunto da patch-dockerfile-java.sh -- il patch e' idempotente e viene
# riapplicato automaticamente da claudebox se il file e' in .devcontainer/

USER root

# 1. Eclipse Temurin 21 JDK via repo Adoptium (cross-distro, cross-arch)
RUN apt-get update && apt-get install -y --no-install-recommends \\
        wget gnupg apt-transport-https ca-certificates \\
    && wget -qO - https://packages.adoptium.net/artifactory/api/gpg/key/public \\
        | gpg --dearmor -o /usr/share/keyrings/adoptium.gpg \\
    && chmod a+r /usr/share/keyrings/adoptium.gpg \\
    && . /etc/os-release \\
    && echo "deb [signed-by=/usr/share/keyrings/adoptium.gpg] https://packages.adoptium.net/artifactory/deb \${VERSION_CODENAME} main" \\
        > /etc/apt/sources.list.d/adoptium.list \\
    && apt-get update && apt-get install -y --no-install-recommends temurin-21-jdk \\
    && apt-get clean && rm -rf /var/lib/apt/lists/* \\
    && ln -sfn "\$(dirname \$(dirname \$(readlink -f /usr/bin/java)))" /usr/local/java-21

ENV JAVA_HOME=/usr/local/java-21
ENV PATH="\${JAVA_HOME}/bin:\${PATH}"

# 2. Maven ${MAVEN_VERSION} da Apache archive (conserva TUTTE le versioni; dlcdn tiene solo le ultime)
RUN curl -fsSL \\
    "https://archive.apache.org/dist/maven/maven-3/${MAVEN_VERSION}/binaries/apache-maven-${MAVEN_VERSION}-bin.tar.gz" \\
    | tar -xzC /opt \\
    && ln -s "/opt/apache-maven-${MAVEN_VERSION}" /opt/maven \\
    && ln -sf /opt/maven/bin/mvn      /usr/local/bin/mvn \\
    && ln -sf /opt/maven/bin/mvnDebug /usr/local/bin/mvnDebug

ENV MAVEN_HOME=/opt/maven
ENV PATH="\${MAVEN_HOME}/bin:\${PATH}"

# 3. Persist env anche per login shell (/etc/profile.d sourced da zsh/bash)
RUN printf '%s\\n' \\
        'export JAVA_HOME=/usr/local/java-21' \\
        'export MAVEN_HOME=/opt/maven' \\
        'export PATH="\$JAVA_HOME/bin:\$MAVEN_HOME/bin:\$PATH"' \\
        > /etc/profile.d/java-maven.sh \\
    && chmod +x /etc/profile.d/java-maven.sh

# 4. Smoke test: fallisce la build se qualcosa non va
RUN java -version 2>&1 && mvn --version && which java && which mvn

USER node
$MARKER_END
EOF

    ok "Dockerfile patchato ($DOCKERFILE): Java 21 + Maven ${MAVEN_VERSION}."
}

# ── remove ─────────────────────────────────────────────────────────────────────
cmd_remove() {
    [ -n "$DOCKERFILE" ] || err "Dockerfile non trovato."

    if ! grep -qF "$MARKER_BEGIN" "$DOCKERFILE"; then
        ok "Nessun patch Java trovato in $DOCKERFILE. Niente da rimuovere."
        return 0
    fi

    # Rimuove tutto tra i marker. sed -i ha sintassi diversa su GNU vs BSD (macOS).
    if sed --version 2>/dev/null | grep -q GNU; then
        sed -i "/^${MARKER_BEGIN}$/,/^${MARKER_END}$/d" "$DOCKERFILE"
    else
        sed -i '' "/^${MARKER_BEGIN}$/,/^${MARKER_END}$/d" "$DOCKERFILE"
    fi

    ok "Blocco patch Java rimosso da $DOCKERFILE."
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

    echo -n "  Patch Java applicato : "
    if grep -qF "$MARKER_BEGIN" "$DOCKERFILE"; then
        local ver; ver=$(grep -oE 'maven-[0-9]+\.[0-9]+\.[0-9]+' "$DOCKERFILE" | head -1 || echo "?")
        echo -e "${GREEN}si'${NC}  ($ver)"
    else
        echo -e "${YELLOW}no${NC}  (./patch-dockerfile-java.sh patch)"
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

  patch-dockerfile-java.sh -- aggiunge Java 21 + Maven al Dockerfile claudebox

  USO
    ./patch-dockerfile-java.sh [comando]

  COMANDI
    patch    Aggiunge Java 21 + Maven ${MAVEN_VERSION} (default, idempotente)
    remove   Rimuove il blocco patch
    status   Mostra lo stato corrente
    help     Mostra questo messaggio

  POSIZIONAMENTO CONSIGLIATO
    .devcontainer/patch-dockerfile-java.sh
    -> claudebox lo esegue automaticamente dopo init/update e prima di up.

  VARIABILI AMBIENTE
    MAVEN_VERSION  Versione Maven (default: ${MAVEN_VERSION})
    DOCKERFILE     Path al Dockerfile da patchare (override auto-discovery)

  WORKFLOW AUTOMATICO
    cp patch-dockerfile-java.sh .devcontainer/
    claudebox start -y

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
