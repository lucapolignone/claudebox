#!/usr/bin/env bash
# patch-dockerfile-node22.sh -- porta a node 22 il Dockerfile di claudebox
#
# USO:
#   ./patch-dockerfile-node22.sh              # applica il patch (idempotente)
#   ./patch-dockerfile-node22.sh patch        # idem
#   ./patch-dockerfile-node22.sh remove       # rimuove il blocco patch
#   ./patch-dockerfile-node22.sh status       # mostra stato corrente
#
# POSIZIONAMENTO:
#   - .devcontainer/patch-dockerfile-node22.sh   (preferito, scoperto da claudebox)
#   - ./patch-dockerfile-node22.sh               (project root, manuale)
#
#   Se posizionato in una di queste location, claudebox lo esegue automaticamente
#   dopo ogni 'init', 'update' e prima di ogni 'up'.
#
# COSA INSTALLA:
#   - node 22 (l'ultimo del canale), che PRENDE IL POSTO di quello dell'immagine
#
# PERCHE':
#   L'immagine di claudebox e' basata su node 20. Un progetto che dichiara
#   "engines: >=22" -- e la cui CI usa 22 -- dentro non ci si costruisce: le
#   prove falliscono, oppure passano su un runtime diverso da quello che
#   giudichera' la fusione, che e' peggio.
#
#   LA PATCH DOTNET DICE, A CHIARE LETTERE, CHE NODE NON VA AGGIUNTO:
#   "aggiungerne un secondo vorrebbe dire due runtime che litigano sul PATH per
#   niente". Ha ragione, e questa patch non la contraddice: non ne aggiunge un
#   secondo, sostituisce il primo. Il tarball si estrae in /usr/local, che e'
#   esattamente dove l'immagine node tiene il suo, quindi dopo il blocco il node
#   sul PATH resta UNO.
#
#   Claude Code non viene toccato, ed e' misurato e non dedotto: sta in
#   /usr/local/share/npm-global/lib/node_modules/@anthropic-ai/claude-code, che
#   il tarball di node non contiene. tar sovrascrive cio' che porta, non
#   cancella cio' che trova.
#
# METODO:
#   Il tarball ufficiale da nodejs.org, canale e non versione fissa: un numero
#   scritto qui invecchia in silenzio. Si fissa con NODE_CHANNEL quando serve
#   riprodurre una build vecchia.
#
#   Si prende il .tar.gz e non il .tar.xz -- 15 MB in piu' da scaricare, ma
#   niente xz-utils da installare per aprirlo: un pacchetto in meno e' un pezzo
#   in meno che si rompe.
#
#   Il controllo sha256 prova L'INTEGRITA' DEL TRASFERIMENTO, NON LA PROVENIENZA:
#   SHASUMS256.txt arriva dallo stesso host del tarball, quindi chi potesse
#   servire l'uno potrebbe servire l'altro. Prende un file troncato o un mirror
#   rotto, non un avversario. E' scritto perche' un controllo che si crede una
#   difesa e' peggio di nessun controllo.
#
# NON C'E' IL GEMELLO .ps1, come per la patch dotnet e per la stessa ragione:
# non ho una macchina Windows con claudebox su cui provarlo, e un file
# PowerShell che nessuno ha mai eseguito e' peggio di un file assente -- il
# primo promette, il secondo no.
#
# VARIABILI AMBIENTE:
#   NODE_CHANNEL   Canale di nodejs.org (default: latest-v22.x)
#   DOCKERFILE     Path al Dockerfile (override auto-discovery)

set -euo pipefail

# ── Configurazione ─────────────────────────────────────────────────────────────
NODE_CHANNEL="${NODE_CHANNEL:-latest-v22.x}"
MARKER_BEGIN="# >>> CLAUDEBOX_PATCH_NODE22_BEGIN >>>"
MARKER_END="# <<< CLAUDEBOX_PATCH_NODE22_END <<<"

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
        ok "Patch node22 gia' presente in $DOCKERFILE. Niente da fare."
        return 0
    fi

    # Backup una tantum (non sovrascrive se esiste gia')
    if [ ! -f "${DOCKERFILE}.orig" ]; then
        cp "$DOCKERFILE" "${DOCKERFILE}.orig"
        ok "Backup in ${DOCKERFILE}.orig"
    fi

    # ATTENZIONE, e' la trappola di questo file: il blocco qui sotto contiene
    # variabili di shell ($arch, $file) che devono arrivare intatte fino a
    # Docker. Con un heredoc NON quotato -- quello che usano le altre patch di
    # questa cartella -- bash le espanderebbe qui, scrivendole VUOTE nel
    # Dockerfile, e la build fallirebbe con un messaggio che non parla di
    # questo. Quindi: heredoc quotato per il corpo, e le poche cose che vanno
    # sostituite (marker, canale) scritte fuori con printf.
    #
    # Dentro il blocco, le variabili della shell si scrivono NUDE ($file, $arch),
    # e ${NODE_CHANNEL} no perche' e' un ARG dichiarato: misurato costruendo
    # un'immagine, non dedotto -- $arch, $na e $file sono arrivati intatti alla
    # shell e il canale l'ha sostituito Docker.
    #
    # Proteggerle con "\$" e' l'errore che sembra prudenza, e costa una build:
    # con "\$(dpkg --print-architecture)" la barra e' arrivata fino alla shell,
    # che dentro le virgolette l'ha letta come un dollaro letterale. "arch"
    # valeva la stringa "$(dpkg --print-architecture)", il case cadeva sul ramo
    # *, e il messaggio parlava di un'architettura non prevista su una amd64
    # normalissima -- cioe' accusava la macchina di un difetto del Dockerfile.
    #
    # L'unico "\$" che resta e' in fondo al grep, dove il dollaro e' l'ancora
    # di fine riga della regex: quello attraversa e funziona (provato: il
    # sha256sum del tarball torna OK).
    {
        printf '\n%s\n' "$MARKER_BEGIN"
        printf '%s\n' "# node 22 (canale ${NODE_CHANNEL})"
        printf '%s\n' "# Aggiunto da patch-dockerfile-node22.sh -- riapplicato automaticamente da claudebox."
        printf '%s\n' "# NON affianca un secondo runtime: sostituisce quello dell'immagine, perche'"
        printf '%s\n' "# /usr/local e' dove l'immagine node tiene il suo. Claude Code sta altrove"
        printf '%s\n' "# (/usr/local/share/npm-global) e il tarball non lo contiene."
        printf '\n'
        printf 'ARG NODE_CHANNEL=%s\n' "$NODE_CHANNEL"
        cat <<'EOF'

USER root

# 1. Il tarball ufficiale, scelto leggendo SHASUMS256.txt del canale: cosi' la
#    versione esatta non e' scritta da nessuna parte e non invecchia.
#    Il .tar.gz e non il .tar.xz: 15 MB in piu', ma niente xz-utils da
#    installare per aprirlo.
#    Il controllo sha256 prova l'integrita' del trasferimento, non la
#    provenienza: SHASUMS256.txt viene dallo stesso host del tarball.
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      amd64) na=x64 ;; \
      arm64) na=arm64 ;; \
      *) echo "architettura non prevista: $arch" >&2; exit 1 ;; \
    esac; \
    cd /tmp; \
    curl -fsSLO "https://nodejs.org/dist/${NODE_CHANNEL}/SHASUMS256.txt"; \
    file="$(grep -oE "node-v[0-9.]+-linux-$na[.]tar[.]gz" SHASUMS256.txt | head -n 1)"; \
    [ -n "$file" ] || { echo "nessun tarball linux-$na nel canale ${NODE_CHANNEL}" >&2; exit 1; }; \
    curl -fsSLO "https://nodejs.org/dist/${NODE_CHANNEL}/$file"; \
    grep " $file\$" SHASUMS256.txt | sha256sum -c -; \
    rm -rf /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/corepack \
           /usr/local/include/node; \
    tar -xzf "$file" -C /usr/local --strip-components=1 --no-same-owner \
        --exclude CHANGELOG.md --exclude LICENSE --exclude README.md; \
    rm -f "$file" SHASUMS256.txt

# 2. Smoke test: node e' 22 e npm risponde.
RUN node -v | grep -E "^v22[.]" && npm -v

# 3. Smoke test che il precedente non fa, ed e' quello che conta: un'installazione
#    VERA, piccola. Un npm meta' vecchio e meta' nuovo risponde benissimo a
#    "npm -v" e muore alla prima "npm ci", con "Class extends value undefined"
#    -- un messaggio che di versioni miste non parla. E' la ragione per cui la
#    riga qui sopra rimuove il vecchio npm invece di estrarci sopra: tar
#    sovrascrive cio' che porta e non cancella cio' che trova, quindi i file che
#    10.8.2 aveva e 10.9.8 non ha restavano sotto a mescolarsi.
RUN set -eux; \
    d="$(mktemp -d)"; cd "$d"; \
    npm init -y > /dev/null; \
    npm install --no-audit --no-fund --loglevel=error is-number@7.0.0; \
    node -e "process.exit(require('$d/node_modules/is-number')(7) ? 0 : 1)"; \
    cd /; rm -rf "$d"

# 4. E che Claude Code sia ancora al suo posto. Sostituire il runtime sotto
#    l'agent e' l'unico modo in cui questa patch puo' fare un danno grosso, e
#    sarebbe silenzioso fino al primo avvio. Sta in npm-global, che il tarball
#    non contiene -- ma e' una cosa da verificare, non da dare per scontata.
RUN test -x /usr/local/share/npm-global/bin/claude \
    || test -L /usr/local/share/npm-global/bin/claude

USER node
EOF
        printf '%s\n' "$MARKER_END"
    } >> "$DOCKERFILE"

    ok "Dockerfile patchato ($DOCKERFILE): node 22 dal canale ${NODE_CHANNEL}."
}

# ── remove ─────────────────────────────────────────────────────────────────────
cmd_remove() {
    [ -n "$DOCKERFILE" ] || err "Dockerfile non trovato."

    if ! grep -qF "$MARKER_BEGIN" "$DOCKERFILE"; then
        ok "Nessun patch node22 trovato in $DOCKERFILE. Niente da rimuovere."
        return 0
    fi

    # Rimuove tutto tra i marker. sed -i ha sintassi diversa su GNU vs BSD (macOS).
    if sed --version 2>/dev/null | grep -q GNU; then
        sed -i "/^${MARKER_BEGIN}$/,/^${MARKER_END}$/d" "$DOCKERFILE"
    else
        sed -i '' "/^${MARKER_BEGIN}$/,/^${MARKER_END}$/d" "$DOCKERFILE"
    fi

    ok "Blocco patch node22 rimosso da $DOCKERFILE."
}

# ── status ─────────────────────────────────────────────────────────────────────
cmd_status() {
    echo ""
    echo -n "  Dockerfile trovato     : "
    if [ -n "$DOCKERFILE" ]; then
        echo -e "${GREEN}si'${NC}  ($DOCKERFILE)"
    else
        echo -e "${YELLOW}no${NC}  (claudebox init non ancora eseguito)"
        echo ""
        return
    fi

    echo -n "  Patch node22 applicato : "
    if grep -qF "$MARKER_BEGIN" "$DOCKERFILE"; then
        echo -e "${GREEN}si'${NC}  (canale $(grep -m1 '^ARG NODE_CHANNEL=' "$DOCKERFILE" | cut -d= -f2))"
    else
        echo -e "${YELLOW}no${NC}  (./patch-dockerfile-node22.sh patch)"
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

  patch-dockerfile-node22.sh -- porta a node 22 il Dockerfile claudebox

  USO
    ./patch-dockerfile-node22.sh [comando]

  COMANDI
    patch    Porta node a 22 (default, idempotente)
    remove   Rimuove il blocco patch
    status   Mostra lo stato corrente
    help     Mostra questo messaggio

  POSIZIONAMENTO CONSIGLIATO
    .devcontainer/patch-dockerfile-node22.sh
    -> claudebox lo esegue automaticamente dopo init/update e prima di up.

  VARIABILI AMBIENTE
    NODE_CHANNEL   Canale di nodejs.org (default: latest-v22.x)
    DOCKERFILE     Path al Dockerfile da patchare (override auto-discovery)

  WORKFLOW AUTOMATICO
    cp patch-dockerfile-node22.sh .devcontainer/
    claudebox start -y

  COSA OTTIENI NEL CONTAINER
    node 22    Al posto del 20 dell'immagine, non accanto: il tarball si estrae
               in /usr/local, che e' dove l'immagine node tiene il suo. Serve ai
               progetti che dichiarano "engines: >=22", che sul 20 non si
               costruiscono. Claude Code resta dov'e' -- sta in
               /usr/local/share/npm-global, che il tarball non contiene -- e la
               build lo verifica invece di darlo per scontato.

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
