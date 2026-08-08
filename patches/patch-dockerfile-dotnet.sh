#!/usr/bin/env bash
# patch-dockerfile-dotnet.sh -- aggiunge l'SDK .NET al Dockerfile di claudebox
#
# USO:
#   ./patch-dockerfile-dotnet.sh              # applica il patch (idempotente)
#   ./patch-dockerfile-dotnet.sh patch        # idem
#   ./patch-dockerfile-dotnet.sh remove       # rimuove il blocco patch
#   ./patch-dockerfile-dotnet.sh status       # mostra stato corrente
#
# POSIZIONAMENTO:
#   Metti questo file in UNA di queste posizioni:
#     - .devcontainer/patch-dockerfile-dotnet.sh   (preferito, scoperto da claudebox)
#     - ./patch-dockerfile-dotnet.sh               (project root, manuale)
#
#   Se posizionato in .devcontainer/, claudebox lo esegue AUTOMATICAMENTE
#   dopo ogni 'init' e 'update', e anche prima di ogni 'up' come safety net.
#
# NODE NON E' QUI, ED E' VOLUTO: l'immagine di claudebox e' gia' basata su node
# (v20 su Debian 12), perche' Claude Code e' un programma node. Aggiungerne un
# secondo vorrebbe dire due runtime che litigano sul PATH per niente.
#
# NON C'E' IL GEMELLO .ps1, a differenza degli altri patch di questa cartella, e
# la ragione e' scritta invece che sottintesa: non ho una macchina Windows con
# claudebox su cui provarlo, e un file PowerShell che nessuno ha mai eseguito e'
# peggio di un file assente -- il primo promette, il secondo no.

set -euo pipefail

# ── Configurazione ─────────────────────────────────────────────────────────────
# Il canale e non una versione fissa: le patch di sicurezza dell'SDK escono spesso
# e un numero scritto qui invecchia in silenzio. Si fissa con DOTNET_CHANNEL
# quando serve riprodurre una build vecchia.
DOTNET_CHANNEL="${DOTNET_CHANNEL:-10.0}"
MARKER_BEGIN="# >>> CLAUDEBOX_PATCH_DOTNET_BEGIN >>>"
MARKER_END="# <<< CLAUDEBOX_PATCH_DOTNET_END <<<"

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
        ok "Patch .NET gia' presente in $DOCKERFILE. Niente da fare."
        return 0
    fi

    # Backup una tantum (non sovrascrive se esiste gia')
    if [ ! -f "${DOCKERFILE}.orig" ]; then
        cp "$DOCKERFILE" "${DOCKERFILE}.orig"
        ok "Backup in ${DOCKERFILE}.orig"
    fi

    cat >> "$DOCKERFILE" <<EOF

$MARKER_BEGIN
# SDK .NET ${DOTNET_CHANNEL}
# Aggiunto da patch-dockerfile-dotnet.sh -- il patch e' idempotente e viene
# riapplicato automaticamente da claudebox se il file e' in .devcontainer/

USER root

# 1. L'SDK, con lo script ufficiale invece del feed apt di Microsoft.
#
#    Lo script vale su ogni distro e ha il canale come argomento; il feed apt ha
#    un pacchetto per versione di distro, e su bookworm la versione nuova arriva
#    quando arriva. Qui la scelta e' fra "funziona ovunque" e "si aggiorna con il
#    sistema", e in un container che si ricostruisce da zero la seconda non vale
#    niente.
#
#    libicu NON viene installato: c'e' gia' nell'immagine (libicu72), e serve
#    davvero -- SbxKitManager compila con InvariantGlobalization=false, quindi
#    senza ICU non parte affatto invece di partire con le regole sbagliate.
RUN apt-get update && apt-get install -y --no-install-recommends \\
        curl ca-certificates libstdc++6 zlib1g \\
    && apt-get clean && rm -rf /var/lib/apt/lists/* \\
    && curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh \\
    && chmod +x /tmp/dotnet-install.sh \\
    && /tmp/dotnet-install.sh --channel ${DOTNET_CHANNEL} --install-dir /usr/share/dotnet \\
    && rm /tmp/dotnet-install.sh \\
    && ln -sf /usr/share/dotnet/dotnet /usr/local/bin/dotnet

ENV DOTNET_ROOT=/usr/share/dotnet
ENV PATH="\${DOTNET_ROOT}:\${DOTNET_ROOT}/tools:\${PATH}"
# Niente telemetria e niente pistolotto di benvenuto: il primo comando dentro una
# sandbox nuova lo da' spesso un agent, e due schermate di saluti sono due
# schermate che finiscono in un log che qualcuno dovra' leggere.
ENV DOTNET_CLI_TELEMETRY_OPTOUT=1
ENV DOTNET_NOLOGO=1

# 2. Persist env anche per login shell (/etc/profile.d sourced da zsh/bash)
RUN printf '%s\\n' \\
        'export DOTNET_ROOT=/usr/share/dotnet' \\
        'export DOTNET_CLI_TELEMETRY_OPTOUT=1' \\
        'export DOTNET_NOLOGO=1' \\
        'export PATH="\$DOTNET_ROOT:\$DOTNET_ROOT/tools:\$PATH"' \\
        > /etc/profile.d/dotnet.sh \\
    && chmod +x /etc/profile.d/dotnet.sh

# 3. La cache dei pacchetti appartiene all'utente che compila, non a root.
#    Senza questo il primo "dotnet restore" da utente node scrive in una cartella
#    che non esiste ancora e la crea con i permessi del momento -- che e' come si
#    ottiene un restore che funziona una volta e poi no.
RUN mkdir -p /home/node/.nuget /home/node/.dotnet \\
    && chown -R node:node /home/node/.nuget /home/node/.dotnet

# 4. Smoke test: fallisce la build se qualcosa non va
RUN dotnet --info && which dotnet

USER node
$MARKER_END
EOF

    ok "Dockerfile patchato ($DOCKERFILE): SDK .NET ${DOTNET_CHANNEL}."
}

# ── remove ─────────────────────────────────────────────────────────────────────
cmd_remove() {
    [ -n "$DOCKERFILE" ] || err "Dockerfile non trovato."

    if ! grep -qF "$MARKER_BEGIN" "$DOCKERFILE"; then
        ok "Nessun patch .NET trovato in $DOCKERFILE. Niente da rimuovere."
        return 0
    fi

    # Rimuove tutto tra i marker. sed -i ha sintassi diversa su GNU vs BSD (macOS).
    if sed --version 2>/dev/null | grep -q GNU; then
        sed -i "/^${MARKER_BEGIN}$/,/^${MARKER_END}$/d" "$DOCKERFILE"
    else
        sed -i '' "/^${MARKER_BEGIN}$/,/^${MARKER_END}$/d" "$DOCKERFILE"
    fi

    ok "Blocco patch .NET rimosso da $DOCKERFILE."
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

    echo -n "  Patch .NET applicato : "
    if grep -qF "$MARKER_BEGIN" "$DOCKERFILE"; then
        local ver; ver=$(grep -oE -- '--channel [0-9]+\.[0-9]+' "$DOCKERFILE" | head -1 || echo "?")
        echo -e "${GREEN}si'${NC}  ($ver)"
    else
        echo -e "${YELLOW}no${NC}  (./patch-dockerfile-dotnet.sh patch)"
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

  patch-dockerfile-dotnet.sh -- aggiunge l'SDK .NET al Dockerfile claudebox

  USO
    ./patch-dockerfile-dotnet.sh [comando]

  COMANDI
    patch    Aggiunge l'SDK .NET ${DOTNET_CHANNEL} (default, idempotente)
    remove   Rimuove il blocco patch
    status   Mostra lo stato corrente
    help     Mostra questo messaggio

  VARIABILI AMBIENTE
    DOTNET_CHANNEL   Canale dell'SDK (default: ${DOTNET_CHANNEL})

  POSIZIONAMENTO CONSIGLIATO
    cp patch-dockerfile-dotnet.sh .devcontainer/

HELP
}

# ── Entry point ────────────────────────────────────────────────────────────────
case "${1:-patch}" in
    patch)   cmd_patch ;;
    remove)  cmd_remove ;;
    status)  cmd_status ;;
    help|-h|--help) cmd_help ;;
    *) err "Comando sconosciuto: $1 (usa: patch | remove | status | help)" ;;
esac
