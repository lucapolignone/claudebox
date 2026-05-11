<#
.SYNOPSIS
    patch-dockerfile-glab.ps1 -- aggiunge la CLI glab (GitLab) al Dockerfile claudebox.

.DESCRIPTION
    Equivalente PowerShell di patch-dockerfile-glab.sh. Idempotente.

.PARAMETER Command
    patch (default) | remove | status | help

.EXAMPLE
    .\patch-dockerfile-glab.ps1
    .\patch-dockerfile-glab.ps1 patch
    .\patch-dockerfile-glab.ps1 remove
#>
param([string]$Command = 'patch')

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# --- Configurazione ------------------------------------------------------------
$GlabVersion = if ($env:GLAB_VERSION) { $env:GLAB_VERSION } else { '1.49.0' }
$MarkerBegin = '# >>> CLAUDEBOX_PATCH_GLAB_BEGIN >>>'
$MarkerEnd   = '# <<< CLAUDEBOX_PATCH_GLAB_END <<<'

# --- Output helpers ------------------------------------------------------------
function Write-Info ($msg) { Write-Host "  $([char]0x25B8) $msg" -ForegroundColor Cyan }
function Write-Ok   ($msg) { Write-Host "  $([char]0x2714) $msg" -ForegroundColor Green }
function Write-Warn ($msg) { Write-Host "  $([char]0x26A0) $msg" -ForegroundColor Yellow }
function Write-Err  ($msg) { Write-Host "  $([char]0x2716) $msg" -ForegroundColor Red; exit 1 }

# --- Dockerfile discovery -----------------------------------------------------
function Find-Dockerfile {
    $candidates = @($env:DOCKERFILE, 'Dockerfile', '.devcontainer\Dockerfile')
    foreach ($c in $candidates) {
        if ([string]::IsNullOrEmpty($c)) { continue }
        if (Test-Path -LiteralPath $c) { return $c }
    }
    return $null
}

$Dockerfile = Find-Dockerfile

# --- patch --------------------------------------------------------------------
function Invoke-Patch {
    if (-not $Dockerfile) {
        Write-Err "Dockerfile non trovato (cercato in .\Dockerfile e .\.devcontainer\Dockerfile). Esegui prima: claudebox init"
    }
    $content = Get-Content -LiteralPath $Dockerfile -Raw
    if ($content -like "*$MarkerBegin*") {
        Write-Ok "Patch glab gia' presente in $Dockerfile. Niente da fare."
        return
    }
    $backup = "$Dockerfile.orig"
    if (-not (Test-Path -LiteralPath $backup)) {
        Copy-Item -LiteralPath $Dockerfile -Destination $backup
        Write-Ok "Backup in $backup"
    }
    $block = @"

$MarkerBegin
# GitLab CLI 'glab' v$GlabVersion
# Aggiunto da patch-dockerfile-glab.ps1 -- riapplicato automaticamente da claudebox.
# Metodo: download binario dal release ufficiale (GitLab Releases) e install in
# /usr/local/bin. Funziona su amd64 e arm64.

USER root

ARG GLAB_VERSION=$GlabVersion
RUN set -eux; \
    arch="`$(dpkg --print-architecture)"; \
    case "`$arch" in \
        amd64) glab_arch="amd64" ;; \
        arm64) glab_arch="arm64" ;; \
        *) echo "unsupported arch: `$arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/glab.tgz \
        "https://gitlab.com/gitlab-org/cli/-/releases/v`${GLAB_VERSION}/downloads/glab_`${GLAB_VERSION}_linux_`${glab_arch}.tar.gz"; \
    tar -xzf /tmp/glab.tgz -C /tmp; \
    install -m 0755 /tmp/bin/glab /usr/local/bin/glab; \
    rm -rf /tmp/glab.tgz /tmp/bin /tmp/LICENSE /tmp/README.md 2>/dev/null || true; \
    glab --version

USER node
$MarkerEnd
"@
    Add-Content -LiteralPath $Dockerfile -Value $block -Encoding UTF8
    Write-Ok "Dockerfile patchato ($Dockerfile): glab v$GlabVersion."
}

# --- remove -------------------------------------------------------------------
function Invoke-Remove {
    if (-not $Dockerfile) { Write-Err "Dockerfile non trovato." }
    $content = Get-Content -LiteralPath $Dockerfile -Raw
    if ($content -notlike "*$MarkerBegin*") {
        Write-Ok "Nessun patch glab trovato in $Dockerfile. Niente da rimuovere."
        return
    }
    $reBegin = [regex]::Escape($MarkerBegin)
    $reEnd   = [regex]::Escape($MarkerEnd)
    $pattern = "(?ms)\r?\n?$reBegin.*?$reEnd\r?\n?"
    $newContent = [regex]::Replace($content, $pattern, '')
    Set-Content -LiteralPath $Dockerfile -Value $newContent -Encoding UTF8 -NoNewline
    Write-Ok "Blocco patch glab rimosso da $Dockerfile."
}

# --- status -------------------------------------------------------------------
function Invoke-Status {
    Write-Host ''
    Write-Host -NoNewline "  Dockerfile trovato   : "
    if ($Dockerfile) {
        Write-Host "si'  ($Dockerfile)" -ForegroundColor Green
    } else {
        Write-Host "no  (claudebox init non ancora eseguito)" -ForegroundColor Yellow
        Write-Host ''
        return
    }
    Write-Host -NoNewline "  Patch glab applicato : "
    $content = Get-Content -LiteralPath $Dockerfile -Raw
    if ($content -like "*$MarkerBegin*") {
        $m = [regex]::Match($content, 'ARG GLAB_VERSION=([a-zA-Z0-9._-]+)')
        $ver = if ($m.Success) { $m.Groups[1].Value } else { '?' }
        Write-Host "si'  (glab $ver)" -ForegroundColor Green
    } else {
        Write-Host "no  (./patch-dockerfile-glab.ps1 patch)" -ForegroundColor Yellow
    }
    Write-Host -NoNewline "  Backup orig presente : "
    if (Test-Path -LiteralPath "$Dockerfile.orig") {
        Write-Host "si'  ($Dockerfile.orig)" -ForegroundColor Green
    } else {
        Write-Host "no" -ForegroundColor Yellow
    }
    Write-Host ''
}

# --- help ---------------------------------------------------------------------
function Invoke-Help {
    Write-Host @'

  patch-dockerfile-glab.ps1 -- aggiunge la CLI glab al Dockerfile claudebox

  USO
    .\patch-dockerfile-glab.ps1 [comando]

  COMANDI
    patch    Aggiunge glab (default, idempotente)
    remove   Rimuove il blocco patch
    status   Mostra lo stato corrente
    help     Mostra questo messaggio

  POSIZIONAMENTO CONSIGLIATO
    .devcontainer\patch-dockerfile-glab.ps1
    -> claudebox lo esegue automaticamente dopo init/update e prima di up.

  VARIABILI AMBIENTE
    GLAB_VERSION   Versione glab (default: 1.49.0)
    DOCKERFILE     Path al Dockerfile (override auto-discovery)

  COSA OTTIENI NEL CONTAINER
    glab           CLI ufficiale GitLab (clone, MR, issue, CI, ecc.)

  AUTENTICAZIONE
    Per autenticare glab nel container, claudebox puo' iniettare le credenziali
    GitLab dell'host ($GITLAB_TOKEN env var + ~/.config/glab-cli/ in RO).
    L'opt-in viene chiesto a 'claudebox init' o 'claudebox start'.

'@
}

# --- Entry point --------------------------------------------------------------
switch ($Command.ToLower()) {
    'patch'  { Invoke-Patch  }
    'remove' { Invoke-Remove }
    'status' { Invoke-Status }
    'help'   { Invoke-Help   }
    '-h'     { Invoke-Help   }
    '--help' { Invoke-Help   }
    default  { Write-Err "Comando sconosciuto: $Command  (usa: patch | remove | status | help)" }
}
