#Requires -Version 5.1
<#
.SYNOPSIS
    patch-dockerfile-docker.ps1 -- aggiunge Docker CLI + Buildx + Compose v2 al Dockerfile di claudebox

.DESCRIPTION
    Installa nel container il client Docker e i plugin buildx/compose dal repo
    ufficiale download.docker.com. NON installa il daemon dockerd: il modello e'
    Docker-outside-of-Docker, il container parla al docker dell'HOST tramite il
    socket Unix.

.PARAMETER Command
    Comando: patch | remove | status | help (default: patch)

.NOTES
    POSIZIONAMENTO CONSIGLIATO:
        .devcontainer\patch-dockerfile-docker.ps1
    claudebox lo esegue AUTOMATICAMENTE dopo init/update e prima di up.

    REQUISITO RUNTIME (importante!):
        Il container deve montare il socket Docker dell'host:
            -v /var/run/docker.sock:/var/run/docker.sock
        Senza il bind mount, qualsiasi comando docker fallira' con:
            Cannot connect to the Docker daemon at unix:///var/run/docker.sock

    NOTE GID (Linux):
        Il GID del gruppo 'docker' dentro il container quasi certamente NON
        matcha quello del docker.sock host. Su macOS/Windows con Docker Desktop
        nessun problema (il socket e' esposto world-rw nella VM). Su Linux:
        chmod 666 sul socket (solo dev) oppure --group-add con il GID del
        socket host (claudebox lo gestisce automaticamente).

    COSA INSTALLA:
        docker             Client (run, ps, build, push, ...)
        docker buildx      Build multi-arch con BuildKit
        docker compose     Compose v2 (plugin, NON 'docker-compose' v1)

.EXAMPLE
    Copy-Item patch-dockerfile-docker.ps1 .devcontainer\
    claudebox start -y

.EXAMPLE
    $env:DOCKER_CHANNEL = 'test'
    .\patch-dockerfile-docker.ps1 patch
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
if (-not $env:DOCKER_CHANNEL) { $env:DOCKER_CHANNEL = 'stable' }
$DOCKER_CHANNEL = $env:DOCKER_CHANNEL
$MARKER_BEGIN   = '# >>> CLAUDEBOX_PATCH_DOCKER_BEGIN >>>'
$MARKER_END     = '# <<< CLAUDEBOX_PATCH_DOCKER_END <<<'

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
        Write-Ok "Patch docker gia' presente in $DOCKERFILE. Niente da fare."
        return
    }

    $backupPath = "$DOCKERFILE.orig"
    if (-not (Test-Path -LiteralPath $backupPath)) {
        Copy-Item -LiteralPath $DOCKERFILE -Destination $backupPath
        Write-Ok "Backup in $backupPath"
    }

    # IMPORTANTE: la line-continuation del Dockerfile e' '\' (backslash).
    # In una here-string PowerShell @"..."@ i backslash sono LETTERALI: basta
    # scriverli cosi' come sono. NON usare ` `` ` (escape per backtick literale)
    # come continuation, che produce ` ` ` nel file e Docker rifiuta il parse.
    $patch = @"


$MARKER_BEGIN
# Docker CLI + Buildx + Compose v2 (Docker-outside-of-Docker)
# Aggiunto da patch-dockerfile-docker.ps1 -- riapplicato automaticamente da claudebox.
#
# Modello: il container NON ha un daemon dockerd proprio. Parla al docker
# dell'HOST via socket Unix. A runtime serve:
#   -v /var/run/docker.sock:/var/run/docker.sock

USER root

# 1. Repo ufficiale Docker (cross-distro: rileva ubuntu vs debian dal codename)
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg \
    && install -m 0755 -d /etc/apt/keyrings \
    && . /etc/os-release \
    && DOCKER_DISTRO=`$( [ "`$ID" = "ubuntu" ] && echo ubuntu || echo debian ) \
    && curl -fsSL "https://download.docker.com/linux/`${DOCKER_DISTRO}/gpg" \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg \
    && chmod a+r /etc/apt/keyrings/docker.gpg \
    && echo "deb [arch=`$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/`${DOCKER_DISTRO} `${VERSION_CODENAME} $DOCKER_CHANNEL" \
        > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        docker-ce-cli \
        docker-buildx-plugin \
        docker-compose-plugin \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# 2. Aggiungi 'node' al gruppo docker per parlare al socket senza sudo.
#    Il pacchetto docker-ce-cli NON crea il gruppo (lo fa docker-ce, che non
#    installiamo), quindi lo creiamo a mano. Il GID e' arbitrario; al runtime
#    potrebbe non matchare il GID del docker.sock dell'host (vedi note in cima).
RUN groupadd -f docker && usermod -aG docker node

USER node
$MARKER_END
"@

    # Forza LF ovunque -- Docker legge il file in Linux
    $combined = ($content.TrimEnd() + ($patch -replace "`r`n", "`n")) -replace "`r`n", "`n"
    [System.IO.File]::WriteAllText($DOCKERFILE, $combined)

    Write-Ok "Dockerfile patchato ($DOCKERFILE): docker CLI + buildx + compose ($DOCKER_CHANNEL)."
    Write-Info "Ricorda di montare il socket a runtime: -v /var/run/docker.sock:/var/run/docker.sock"
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
        Write-Ok "Nessun patch docker trovato in $DOCKERFILE. Niente da rimuovere."
        return
    }

    $result = ($kept -join "`n").TrimEnd() + "`n"
    [System.IO.File]::WriteAllText($DOCKERFILE, $result)
    Write-Ok "Blocco patch docker rimosso da $DOCKERFILE."
}

# ── status ─────────────────────────────────────────────────────────────────────
function Show-Status {
    Write-Host ""

    Write-Host "  Dockerfile trovato     : " -NoNewline -ForegroundColor DarkGray
    if ($DOCKERFILE) {
        Write-Host "si'  ($DOCKERFILE)" -ForegroundColor Green
    } else {
        Write-Host "no   (claudebox init non ancora eseguito)" -ForegroundColor Yellow
        Write-Host ""
        return
    }

    Write-Host "  Patch docker applicato : " -NoNewline -ForegroundColor DarkGray
    $content = [System.IO.File]::ReadAllText($DOCKERFILE)
    if ($content.Contains($MARKER_BEGIN)) {
        $ch = [regex]::Match($content, 'download\.docker\.com/linux/[a-z]+ [a-z]+ ([a-z]+)').Groups[1].Value
        if (-not $ch) { $ch = '?' }
        Write-Host "si'  (channel: $ch)" -ForegroundColor Green
    } else {
        Write-Host "no   (.\patch-dockerfile-docker.ps1 patch)" -ForegroundColor Yellow
    }

    Write-Host "  Backup orig presente   : " -NoNewline -ForegroundColor DarkGray
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

  patch-dockerfile-docker.ps1 -- aggiunge Docker CLI + Buildx + Compose v2

  USO
    .\patch-dockerfile-docker.ps1 [comando]

  COMANDI
    patch    Aggiunge Docker CLI + buildx + compose plugin (default, idempotente)
    remove   Rimuove il blocco patch
    status   Mostra lo stato corrente
    help     Mostra questo messaggio

  POSIZIONAMENTO CONSIGLIATO
    .devcontainer\patch-dockerfile-docker.ps1
    -> claudebox lo esegue automaticamente dopo init/update e prima di up.

  VARIABILI AMBIENTE
    DOCKER_CHANNEL   Canale apt Docker: 'stable' (default), 'test'
    DOCKERFILE       Path al Dockerfile (override auto-discovery)

  WORKFLOW AUTOMATICO
    Copy-Item patch-dockerfile-docker.ps1 .devcontainer\
    claudebox start -y

  REQUISITO RUNTIME
    Il container deve montare il socket dell'host:
      -v /var/run/docker.sock:/var/run/docker.sock

  COSA OTTIENI NEL CONTAINER
    docker             Client (run, ps, build, push, ...)
    docker buildx      Build moderno multi-arch con BuildKit
    docker compose     Compose v2 (plugin, NON 'docker-compose' v1)

"@ -ForegroundColor White
}

# ── Entry point ────────────────────────────────────────────────────────────────
switch ($Command) {
    'remove' { Invoke-Remove }
    'status' { Show-Status  }
    'help'   { Show-Help    }
    default  { Invoke-Patch }   # '' o 'patch'
}
