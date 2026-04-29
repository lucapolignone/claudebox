#Requires -Version 5.1
<#
.SYNOPSIS
    patch-dockerfile-uvx.ps1 -- aggiunge uv + uvx al Dockerfile di claudebox

.DESCRIPTION
    Copia i binari uv e uvx dall'immagine ufficiale distroless di Astral
    (ghcr.io/astral-sh/uv) in /usr/local/bin del container. Idempotente.

.PARAMETER Command
    Comando: patch | remove | status | help (default: patch)

.NOTES
    POSIZIONAMENTO CONSIGLIATO:
        .devcontainer\patch-dockerfile-uvx.ps1
    claudebox lo esegue AUTOMATICAMENTE dopo init/update e prima di up.

    COSA INSTALLA:
        uv     Python package manager (pip, venv, project, lock, ecc.)
        uvx    Alias di 'uv tool run', esegue tool Python in env effimero
               (uvx ruff, uvx black, uvx pytest, ecc.)

    METODO: COPY dall'immagine ufficiale distroless. Piu' veloce dello
    standalone installer e con pinning di versione esplicito.

.EXAMPLE
    # Workflow automatico:
    Copy-Item patch-dockerfile-uvx.ps1 .devcontainer\
    claudebox start -y

.EXAMPLE
    # Pinning a una versione specifica:
    $env:UV_VERSION = '0.11.8'
    .\patch-dockerfile-uvx.ps1 patch
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
if (-not $env:UV_VERSION) { $env:UV_VERSION = 'latest' }
$UV_VERSION   = $env:UV_VERSION
$MARKER_BEGIN = '# >>> CLAUDEBOX_PATCH_UVX_BEGIN >>>'
$MARKER_END   = '# <<< CLAUDEBOX_PATCH_UVX_END <<<'

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
        Write-Ok "Patch uvx gia' presente in $DOCKERFILE. Niente da fare."
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
# uv + uvx (Astral) v$UV_VERSION
# Aggiunto da patch-dockerfile-uvx.ps1 -- riapplicato automaticamente da claudebox.
# Metodo: COPY dei binari dall'immagine ufficiale distroless (raccomandato dalla
# documentazione ufficiale uv https://docs.astral.sh/uv/guides/integration/docker/).

USER root

# 1. Copia i binari uv e uvx dall'immagine ufficiale in /usr/local/bin
#    /usr/local/bin e' sempre nel PATH standard, niente ENV PATH override necessari.
COPY --from=ghcr.io/astral-sh/uv:$UV_VERSION /uv /uvx /usr/local/bin/

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
"@

    # Forza LF ovunque -- Docker legge il file in Linux
    $combined = ($content.TrimEnd() + ($patch -replace "`r`n", "`n")) -replace "`r`n", "`n"
    [System.IO.File]::WriteAllText($DOCKERFILE, $combined)

    Write-Ok "Dockerfile patchato ($DOCKERFILE): uv + uvx (v$UV_VERSION)."
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
        Write-Ok "Nessun patch uvx trovato in $DOCKERFILE. Niente da rimuovere."
        return
    }

    $result = ($kept -join "`n").TrimEnd() + "`n"
    [System.IO.File]::WriteAllText($DOCKERFILE, $result)
    Write-Ok "Blocco patch uvx rimosso da $DOCKERFILE."
}

# ── status ─────────────────────────────────────────────────────────────────────
function Show-Status {
    Write-Host ""

    Write-Host "  Dockerfile trovato   : " -NoNewline -ForegroundColor DarkGray
    if ($DOCKERFILE) {
        Write-Host "si'  ($DOCKERFILE)" -ForegroundColor Green
    } else {
        Write-Host "no   (claudebox init non ancora eseguito)" -ForegroundColor Yellow
        Write-Host ""
        return
    }

    Write-Host "  Patch uvx applicato  : " -NoNewline -ForegroundColor DarkGray
    $content = [System.IO.File]::ReadAllText($DOCKERFILE)
    if ($content.Contains($MARKER_BEGIN)) {
        $ver = [regex]::Match($content, 'astral-sh/uv:([a-zA-Z0-9._-]+)').Groups[1].Value
        if (-not $ver) { $ver = '?' }
        Write-Host "si'  (uv $ver)" -ForegroundColor Green
    } else {
        Write-Host "no   (.\patch-dockerfile-uvx.ps1 patch)" -ForegroundColor Yellow
    }

    Write-Host "  Backup orig presente : " -NoNewline -ForegroundColor DarkGray
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

  patch-dockerfile-uvx.ps1 -- aggiunge uv + uvx al Dockerfile claudebox

  USO
    .\patch-dockerfile-uvx.ps1 [comando]

  COMANDI
    patch    Aggiunge uv + uvx (default, idempotente)
    remove   Rimuove il blocco patch
    status   Mostra lo stato corrente
    help     Mostra questo messaggio

  POSIZIONAMENTO CONSIGLIATO
    .devcontainer\patch-dockerfile-uvx.ps1
    -> claudebox lo esegue automaticamente dopo init/update e prima di up.

  VARIABILI AMBIENTE
    UV_VERSION   Versione uv (default: latest)
                 Es: 'latest', '0.11.8', '0.5'
                 Pinna a una versione specifica per builds riproducibili.
    DOCKERFILE   Path al Dockerfile (override auto-discovery)

  WORKFLOW AUTOMATICO
    Copy-Item patch-dockerfile-uvx.ps1 .devcontainer\
    claudebox start -y

  COSA OTTIENI NEL CONTAINER
    uv         Python package manager (pip, venv, project, lock, ecc.)
    uvx        Alias di 'uv tool run' -- esegue tool Python in env effimero
               Es: uvx ruff check .   (esegue ruff senza installarlo)
                   uvx black .        (esegue black senza installarlo)
                   uvx pytest         (esegue pytest senza installarlo)

"@ -ForegroundColor White
}

# ── Entry point ────────────────────────────────────────────────────────────────
switch ($Command) {
    'remove' { Invoke-Remove }
    'status' { Show-Status  }
    'help'   { Show-Help    }
    default  { Invoke-Patch }   # '' o 'patch'
}
