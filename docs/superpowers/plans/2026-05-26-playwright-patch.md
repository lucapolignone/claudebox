# Playwright Patch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Aggiungere `patches/patch-dockerfile-playwright.{sh,ps1}` al repo claudebox, che installa Playwright (Node) + tutti i browser + apt deps nel Dockerfile devcontainer del progetto target.

**Architecture:** Due script template (bash + PowerShell), copia diretta del pattern `patch-dockerfile-uvx.{sh,ps1}` con marker `CLAUDEBOX_PATCH_PLAYWRIGHT_*`, comandi `patch|remove|status|help`, versione pinnabile via `PLAYWRIGHT_VERSION` env var. Le patch sono template — non eseguite dalla repo claudebox stessa, ma copiate dall'utente in `.devcontainer/` del progetto target dove `claudebox.sh:159-200` le scopre per pattern `patch-dockerfile*.sh`.

**Tech Stack:** Bash 3.2 compatibile (macOS), PowerShell 5.1+, GNU/BSD sed compat. Nessuna test suite nel repo — verifica manuale su Dockerfile sintetici.

**Reference docs:**
- Spec: `docs/superpowers/specs/2026-05-26-playwright-patch-design.md`
- Project convention: `CLAUDE.md` sezioni "Convenzioni patch" e "Portabilità".
- Template: `patches/patch-dockerfile-uvx.sh` e `patches/patch-dockerfile-uvx.ps1`.

---

## File Structure

| File | Stato | Responsabilità |
|---|---|---|
| `patches/patch-dockerfile-playwright.sh` | Create | Patch bash idempotente per Dockerfile |
| `patches/patch-dockerfile-playwright.ps1` | Create | Mirror PowerShell della patch |
| `README.md` | Modify | File tree (≈ riga 396) + nuova sezione `### patch-dockerfile-playwright.sh` |
| `CLAUDE.md` | Modify | Lista patches in `patches/` (sezione "Layout della repo") |

Nessun file di test: il repo non ha test suite (`CLAUDE.md`: "Niente backend, niente test"). Verifica per ciascuna patch fatta a mano in `/tmp` su un Dockerfile sintetico.

---

### Task 1: Crea `patches/patch-dockerfile-playwright.sh`

**Files:**
- Create: `patches/patch-dockerfile-playwright.sh`

- [ ] **Step 1: Crea il file con il contenuto completo**

```bash
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
```

- [ ] **Step 2: Rendi il file eseguibile**

Run: `chmod +x patches/patch-dockerfile-playwright.sh`

- [ ] **Step 3: Verifica sintassi bash**

Run: `bash -n patches/patch-dockerfile-playwright.sh && echo OK`
Expected: `OK`

- [ ] **Step 4: Smoke test su Dockerfile sintetico — comando `patch`**

```bash
TMP=$(mktemp -d)
cat > "$TMP/Dockerfile" <<'DOCK'
FROM node:20
USER node
DOCK
( cd "$TMP" && /workspace/patches/patch-dockerfile-playwright.sh patch )
grep -c CLAUDEBOX_PATCH_PLAYWRIGHT_BEGIN "$TMP/Dockerfile"
```
Expected: stampa `1`, file `$TMP/Dockerfile.orig` creato.

- [ ] **Step 5: Verifica idempotenza — secondo `patch` no-op**

```bash
( cd "$TMP" && /workspace/patches/patch-dockerfile-playwright.sh patch ) 2>&1 | tail -1
grep -c CLAUDEBOX_PATCH_PLAYWRIGHT_BEGIN "$TMP/Dockerfile"
```
Expected: messaggio "Patch playwright gia' presente in ... Niente da fare.", count ancora `1`.

- [ ] **Step 6: Verifica comando `status`**

```bash
( cd "$TMP" && /workspace/patches/patch-dockerfile-playwright.sh status )
```
Expected: tutte e tre le righe `Dockerfile trovato`, `Patch playwright applicato`, `Backup orig presente` con `si'`.

- [ ] **Step 7: Verifica versione override**

```bash
( cd "$TMP" && /workspace/patches/patch-dockerfile-playwright.sh remove )
( cd "$TMP" && PLAYWRIGHT_VERSION=1.49.0 /workspace/patches/patch-dockerfile-playwright.sh patch )
grep '@playwright/test@1.49.0' "$TMP/Dockerfile"
```
Expected: stampa la riga `RUN npm install -g @playwright/test@1.49.0`.

- [ ] **Step 8: Verifica comando `remove`**

```bash
( cd "$TMP" && /workspace/patches/patch-dockerfile-playwright.sh remove )
grep -c CLAUDEBOX_PATCH_PLAYWRIGHT "$TMP/Dockerfile" || echo "ZERO MATCHES"
```
Expected: `ZERO MATCHES` (grep esce 1, niente blocco residuo).

- [ ] **Step 9: Cleanup**

Run: `rm -rf "$TMP"`

- [ ] **Step 10: Commit**

```bash
git add patches/patch-dockerfile-playwright.sh
git commit -m "feat(patches): add playwright + browsers patch (bash)"
```

---

### Task 2: Crea `patches/patch-dockerfile-playwright.ps1`

**Files:**
- Create: `patches/patch-dockerfile-playwright.ps1`

PowerShell non è eseguibile in questo devcontainer (Linux). La verifica si basa su parità di logica con `patch-dockerfile-uvx.ps1`. Lo script va testato manualmente su un host Windows in un secondo momento.

- [ ] **Step 1: Crea il file con il contenuto completo**

```powershell
#Requires -Version 5.1
<#
.SYNOPSIS
    patch-dockerfile-playwright.ps1 -- aggiunge Playwright (Node) + browser al Dockerfile claudebox

.DESCRIPTION
    Installa @playwright/test globalmente via npm + tutti i browser (chromium,
    firefox, webkit) + apt deps di sistema. Cache browser in /ms-playwright
    (convenzione Docker ufficiale). Idempotente.

.PARAMETER Command
    Comando: patch | remove | status | help (default: patch)

.NOTES
    POSIZIONAMENTO CONSIGLIATO:
        .devcontainer\patch-dockerfile-playwright.ps1
    claudebox lo esegue AUTOMATICAMENTE dopo init/update e prima di up.

    COSA INSTALLA:
        @playwright/test    CLI Playwright (npx playwright test, codegen, ...)
        /ms-playwright/     Cache system-wide con chromium, firefox, webkit
        apt deps            libnss3, libgbm, fonts, ecc.

    NOTA DIMENSIONI: aggiunge ~700 MB all'immagine finale.

.EXAMPLE
    # Workflow automatico:
    Copy-Item patch-dockerfile-playwright.ps1 .devcontainer\
    claudebox start -y

.EXAMPLE
    # Pinning a una versione specifica:
    $env:PLAYWRIGHT_VERSION = '1.49.0'
    .\patch-dockerfile-playwright.ps1 patch
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('patch', 'remove', 'status', 'help', '')]
    [string]$Command = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Configurazione ─────────────────────────────────────────────────────────────
if (-not $env:PLAYWRIGHT_VERSION) { $env:PLAYWRIGHT_VERSION = 'latest' }
$PLAYWRIGHT_VERSION = $env:PLAYWRIGHT_VERSION
$MARKER_BEGIN = '# >>> CLAUDEBOX_PATCH_PLAYWRIGHT_BEGIN >>>'
$MARKER_END   = '# <<< CLAUDEBOX_PATCH_PLAYWRIGHT_END <<<'

# ── Output helpers ─────────────────────────────────────────────────────────────
function Write-Info ($msg) { Write-Host "  $([char]0x25B8) $msg" -ForegroundColor Cyan   }
function Write-Ok   ($msg) { Write-Host "  $([char]0x2714) $msg" -ForegroundColor Green  }
function Write-Warn ($msg) { Write-Host "  $([char]0x26A0) $msg" -ForegroundColor Yellow }
function Write-Err  ($msg) { Write-Host "  $([char]0x2716) $msg" -ForegroundColor Red; exit 1 }

# ── Dockerfile discovery ───────────────────────────────────────────────────────
function Find-Dockerfile {
    $candidates = @(
        $env:DOCKERFILE,                  # override esplicito via env var
        'Dockerfile',                     # cwd diretto
        '.devcontainer\Dockerfile'        # project root
    )
    foreach ($c in $candidates) {
        if ([string]::IsNullOrWhiteSpace($c)) { continue }
        if (Test-Path -LiteralPath $c -PathType Leaf) { return (Resolve-Path $c).Path }
    }
    return $null
}

$DOCKERFILE = Find-Dockerfile

# ── patch ──────────────────────────────────────────────────────────────────────
function Invoke-Patch {
    if (-not $DOCKERFILE) {
        Write-Err "Dockerfile non trovato (cercato in .\Dockerfile e .\.devcontainer\Dockerfile). Esegui prima: claudebox init"
    }

    $content = [System.IO.File]::ReadAllText($DOCKERFILE)
    if ($content.Contains($MARKER_BEGIN)) {
        Write-Ok "Patch playwright gia' presente in $DOCKERFILE. Niente da fare."
        return
    }

    $backupPath = "$DOCKERFILE.orig"
    if (-not (Test-Path -LiteralPath $backupPath)) {
        Copy-Item -LiteralPath $DOCKERFILE -Destination $backupPath
        Write-Ok "Backup in $backupPath"
    }

    # Blocco Dockerfile -- LF come line ending (gira in container Linux)
    $patch = @"


$MARKER_BEGIN
# Playwright (Node) v$PLAYWRIGHT_VERSION + tutti i browser + apt deps
# Aggiunto da patch-dockerfile-playwright.ps1 -- riapplicato automaticamente da claudebox.
# Cache browser system-wide: convenzione ufficiale Playwright per Docker
# (https://playwright.dev/docs/docker).

USER root

# 1. Cache browser system-wide -- un solo download condiviso fra root e node.
ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright

# 2. CLI @playwright/test globale (npm e' gia' nel devcontainer Anthropic).
RUN npm install -g @playwright/test@$PLAYWRIGHT_VERSION

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
"@

    # Forza LF ovunque -- Docker legge il file in Linux
    $combined = ($content.TrimEnd() + ($patch -replace "`r`n", "`n")) -replace "`r`n", "`n"
    [System.IO.File]::WriteAllText($DOCKERFILE, $combined)

    Write-Ok "Dockerfile patchato ($DOCKERFILE): Playwright + browser (v$PLAYWRIGHT_VERSION)."
}

# ── remove ─────────────────────────────────────────────────────────────────────
function Invoke-Remove {
    if (-not $DOCKERFILE) {
        Write-Err "Dockerfile non trovato."
    }

    $lines   = [System.IO.File]::ReadAllLines($DOCKERFILE)
    $inside  = $false
    $kept    = [System.Collections.Generic.List[string]]::new()
    $removed = $false

    foreach ($line in $lines) {
        if ($line -eq $MARKER_BEGIN) { $inside = $true; $removed = $true; continue }
        if ($line -eq $MARKER_END)   { $inside = $false; continue }
        if (-not $inside)            { $kept.Add($line) }
    }

    if (-not $removed) {
        Write-Ok "Nessun patch playwright trovato in $DOCKERFILE. Niente da rimuovere."
        return
    }

    $result = ($kept -join "`n").TrimEnd() + "`n"
    [System.IO.File]::WriteAllText($DOCKERFILE, $result)
    Write-Ok "Blocco patch playwright rimosso da $DOCKERFILE."
}

# ── status ─────────────────────────────────────────────────────────────────────
function Show-Status {
    Write-Host ""

    Write-Host "  Dockerfile trovato         : " -NoNewline -ForegroundColor DarkGray
    if ($DOCKERFILE) {
        Write-Host "si'  ($DOCKERFILE)" -ForegroundColor Green
    } else {
        Write-Host "no   (claudebox init non ancora eseguito)" -ForegroundColor Yellow
        Write-Host ""
        return
    }

    Write-Host "  Patch playwright applicato : " -NoNewline -ForegroundColor DarkGray
    $content = [System.IO.File]::ReadAllText($DOCKERFILE)
    if ($content.Contains($MARKER_BEGIN)) {
        $ver = [regex]::Match($content, '@playwright/test@([a-zA-Z0-9._-]+)').Groups[1].Value
        if (-not $ver) { $ver = '?' }
        Write-Host "si'  (@playwright/test $ver)" -ForegroundColor Green
    } else {
        Write-Host "no   (.\patch-dockerfile-playwright.ps1 patch)" -ForegroundColor Yellow
    }

    Write-Host "  Backup orig presente       : " -NoNewline -ForegroundColor DarkGray
    if (Test-Path -LiteralPath "$DOCKERFILE.orig") {
        Write-Host "si'  ($DOCKERFILE.orig)" -ForegroundColor Green
    } else {
        Write-Host "no" -ForegroundColor Yellow
    }
    Write-Host ""
}

# ── help ───────────────────────────────────────────────────────────────────────
function Show-Help {
    Write-Host @"

  patch-dockerfile-playwright.ps1 -- aggiunge Playwright (Node) + browser al Dockerfile claudebox

  USO
    .\patch-dockerfile-playwright.ps1 [comando]

  COMANDI
    patch    Aggiunge Playwright + browser (default, idempotente)
    remove   Rimuove il blocco patch
    status   Mostra lo stato corrente
    help     Mostra questo messaggio

  POSIZIONAMENTO CONSIGLIATO
    .devcontainer\patch-dockerfile-playwright.ps1
    -> claudebox lo esegue automaticamente dopo init/update e prima di up.

  VARIABILI AMBIENTE
    PLAYWRIGHT_VERSION  Versione di @playwright/test (default: latest)
                        Es: 'latest', '1.49.0', '1.48'
                        Pinna per builds riproducibili.
    DOCKERFILE          Path al Dockerfile (override auto-discovery)

  WORKFLOW AUTOMATICO
    Copy-Item patch-dockerfile-playwright.ps1 .devcontainer\
    claudebox start -y

  COSA OTTIENI NEL CONTAINER
    @playwright/test    CLI Playwright (npx playwright test, codegen, ...)
    /ms-playwright/     Cache system-wide con chromium, firefox, webkit
    apt deps            libnss3, libgbm, fonts, ecc. (necessarie ai browser)

  NOTA DIMENSIONI
    Aggiunge ~700 MB all'immagine finale (browser + apt deps).

"@ -ForegroundColor White
}

# ── Entry point ────────────────────────────────────────────────────────────────
switch ($Command) {
    'remove' { Invoke-Remove }
    'status' { Show-Status  }
    'help'   { Show-Help    }
    default  { Invoke-Patch }   # '' o 'patch'
}
```

- [ ] **Step 2: Verifica parità con la versione bash**

Run:
```bash
grep -c 'CLAUDEBOX_PATCH_PLAYWRIGHT' patches/patch-dockerfile-playwright.ps1
grep -c 'CLAUDEBOX_PATCH_PLAYWRIGHT' patches/patch-dockerfile-playwright.sh
```
Expected: entrambi `>= 4` (marker BEGIN/END referenziati nel codice + nei marker veri).

Run (verifica che entrambi gli script usano lo stesso blocco Dockerfile):
```bash
diff <(grep -A20 'USER root' patches/patch-dockerfile-playwright.sh | head -25) <(grep -A20 'USER root' patches/patch-dockerfile-playwright.ps1 | head -25) || echo "diff atteso solo per RUN npm syntax \${VAR} vs \$VAR"
```
Expected: differenze attese solo nella sintassi delle variabili (`${PLAYWRIGHT_VERSION}` bash heredoc vs `$PLAYWRIGHT_VERSION` PowerShell here-string). Stesso ordine, stessi comandi.

- [ ] **Step 3: Commit**

```bash
git add patches/patch-dockerfile-playwright.ps1
git commit -m "feat(patches): add playwright + browsers patch (PowerShell)"
```

---

### Task 3: Aggiorna `README.md` con la nuova patch

**Files:**
- Modify: `README.md` (file tree ~ riga 396-409, nuova sezione dopo `### patch-dockerfile-uvx.sh` ~ riga 150)

- [ ] **Step 1: Aggiungi le righe nel file tree (ordine alfabetico: playwright fra java e uvx)**

Trova nel file:
```
│   ├── patch-dockerfile-java.sh        <- patch riusabile (Java 21 + Maven)
│   ├── patch-dockerfile-java.ps1       <- idem per Windows
│   ├── patch-dockerfile-uvx.sh         <- patch riusabile (uv + uvx)
│   ├── patch-dockerfile-uvx.ps1        <- idem per Windows
```

Sostituisci con:
```
│   ├── patch-dockerfile-java.sh        <- patch riusabile (Java 21 + Maven)
│   ├── patch-dockerfile-java.ps1       <- idem per Windows
│   ├── patch-dockerfile-playwright.sh  <- patch riusabile (Playwright + browser)
│   ├── patch-dockerfile-playwright.ps1 <- idem per Windows
│   ├── patch-dockerfile-uvx.sh         <- patch riusabile (uv + uvx)
│   ├── patch-dockerfile-uvx.ps1        <- idem per Windows
```

- [ ] **Step 2: Aggiungi la sezione dedicata dopo quella di `uvx`**

Trova nel file:
```markdown
Comandi: `patch` (default), `remove`, `status`, `help`.

### `patch-dockerfile.sh` — PHP 8 + Composer + rete `yougo-dev`
```

(Cerca la prima occorrenza di `### `patch-dockerfile.sh` —`, quella project-specific.)

Inserisci PRIMA di quella riga il seguente blocco markdown:

````markdown
### `patch-dockerfile-playwright.sh` — Playwright (Node) + browser headless

Aggiunge [Playwright](https://playwright.dev) per test E2E con tutti e tre i browser supportati e tutte le dipendenze apt di sistema. Patch riusabile, scopribile da entrambe le location.

Installa:

- **`@playwright/test`** — CLI Playwright globale via `npm install -g`
- **Browser**: chromium, firefox, webkit (in `/ms-playwright`, cache system-wide condivisa fra `root` e `node`)
- **Dipendenze apt** di sistema: `libnss3`, `libgbm`, font, ecc. — installate via `npx playwright install --with-deps`

```bash
# Dentro al container
npx playwright --version
npx playwright test         # esegue i test
npx playwright codegen      # genera codice da interazioni browser
```

Variabili d'ambiente settate dal patch:

- `PLAYWRIGHT_BROWSERS_PATH=/ms-playwright` — cache system-wide, condivisa fra utenti (convenzione ufficiale Playwright per Docker)

Override versione:

```bash
PLAYWRIGHT_VERSION=1.49.0 ./patch-dockerfile-playwright.sh patch
```

> **Nota dimensioni**: aggiunge ~700 MB all'immagine finale (browser + apt deps). Se ti serve solo un sottoinsieme dei browser oggi non c'è un flag per limitarlo — la patch installa tutti e tre.

Comandi: `patch` (default), `remove`, `status`, `help`.

````

- [ ] **Step 3: Verifica le modifiche**

Run:
```bash
grep -c 'patch-dockerfile-playwright' README.md
```
Expected: `>= 5` (2 nel file tree + 3 nella nuova sezione).

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs(readme): document playwright patch"
```

---

### Task 4: Aggiorna `CLAUDE.md`

**Files:**
- Modify: `CLAUDE.md` (sezione "Layout della repo", lista delle patch ~ righe ~30)

- [ ] **Step 1: Aggiungi la riga playwright nella tabella patch**

Trova nel file:
```
  patch-dockerfile-glab.{sh,ps1}      GitLab CLI 'glab'
  patch-dockerfile-java.{sh,ps1}      Eclipse Temurin 21 + Maven
  patch-dockerfile-uvx.{sh,ps1}       uv + uvx (Astral)
  patch-dockerfile.{sh,ps1}           project-specific (PHP + rete yougo-dev)
```

Sostituisci con:
```
  patch-dockerfile-glab.{sh,ps1}      GitLab CLI 'glab'
  patch-dockerfile-java.{sh,ps1}      Eclipse Temurin 21 + Maven
  patch-dockerfile-playwright.{sh,ps1} Playwright (Node) + browser headless + apt deps
  patch-dockerfile-uvx.{sh,ps1}       uv + uvx (Astral)
  patch-dockerfile.{sh,ps1}           project-specific (PHP + rete yougo-dev)
```

(Ordine alfabetico: `playwright` va fra `java` e `uvx`.)

- [ ] **Step 2: Verifica**

Run: `grep -c 'patch-dockerfile-playwright' CLAUDE.md`
Expected: `1`.

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "docs(claude): add playwright to patches list"
```

---

### Task 5: Final integration check

- [ ] **Step 1: Verifica pattern di discovery (auto-scoperta da claudebox)**

Run:
```bash
ls patches/patch-dockerfile*.sh patches/patch-dockerfile*.ps1
```
Expected: 5 file `.sh` e 5 `.ps1` (docker, glab, java, playwright, uvx; più `patch-dockerfile.sh` project-specific). Conferma che playwright matcha il pattern `patch-dockerfile*.sh` usato in `claudebox.sh:159-200`.

- [ ] **Step 2: Verifica nome marker univoco (no collisione con altre patch)**

Run:
```bash
grep -l CLAUDEBOX_PATCH_PLAYWRIGHT patches/patch-dockerfile-*.sh patches/patch-dockerfile-*.ps1
```
Expected: solo `patches/patch-dockerfile-playwright.sh` e `patches/patch-dockerfile-playwright.ps1`.

- [ ] **Step 3: Verifica git history**

Run: `git log --oneline origin/main..HEAD | head -10`
Expected: 4 commit recenti (.sh, .ps1, README, CLAUDE.md).

- [ ] **Step 4: Verifica nessun file lasciato indietro**

Run: `git status`
Expected: working tree clean.

---

## Out of scope (rimandati esplicitamente)

- **Test end-to-end reali** (`claudebox up` + `npx playwright test` su un progetto vero): richiede un host con Docker + un progetto Playwright pronto. Verifica manuale post-merge, fuori da questo plan.
- **Verifica su Windows**: il `.ps1` non è eseguito qui (devcontainer Linux). Validato per parità di struttura con `patch-dockerfile-uvx.ps1`. Test manuale su host Windows da chi ne ha uno.
- **Selettori di browser** (es. `PLAYWRIGHT_BROWSERS=chromium`): YAGNI, da aggiungere solo se richiesto.
