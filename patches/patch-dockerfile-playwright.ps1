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
