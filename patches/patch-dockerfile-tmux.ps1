#Requires -Version 5.1
<#
.SYNOPSIS
    patch-dockerfile-tmux.ps1 -- aggiunge tmux al Dockerfile di claudebox

.DESCRIPTION
    Installa tmux nel container via apt-get, dai repository che il devcontainer
    Anthropic ha gia'. Idempotente.

.PARAMETER Command
    Comando: patch | remove | status | help (default: patch)

.NOTES
    POSIZIONAMENTO CONSIGLIATO:
        .devcontainer\patch-dockerfile-tmux.ps1
    claudebox lo esegue AUTOMATICAMENTE dopo init/update e prima di up.

    COSA INSTALLA:
        tmux

    PERCHE':
        Il gestore delle sandbox apre il terminale dal browser. Senza tmux la
        sessione muore quando il servizio si riavvia, perche' lo stream di
        "docker exec" muore con lui. Con tmux dentro, il server di tmux resta e
        la sessione con lui: alla riconnessione il gestore fa "tmux attach"
        invece di ricominciare. Il gestore rileva tmux da solo e senza si
        comporta bene lo stesso -- dice che la sessione non sopravvivera' al
        riavvio, invece di prometterlo.

    METODO: apt-get. Nessuna versione da pinnare -- tmux e' un pacchetto Debian
    stabile e un attach che funziona funziona in tutte le versioni che Debian
    spedisce. Aggiunge ~1 MB all'immagine.

.EXAMPLE
    # Workflow automatico:
    Copy-Item patch-dockerfile-tmux.ps1 .devcontainer\
    claudebox start -y

.EXAMPLE
    # Stato corrente, senza toccare niente:
    .\patch-dockerfile-tmux.ps1 status
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
$MARKER_BEGIN = '# >>> CLAUDEBOX_PATCH_TMUX_BEGIN >>>'
$MARKER_END   = '# <<< CLAUDEBOX_PATCH_TMUX_END <<<'

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
        Write-Ok "Patch tmux gia' presente in $DOCKERFILE. Niente da fare."
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
# tmux
# Aggiunto da patch-dockerfile-tmux.ps1 -- riapplicato automaticamente da claudebox.
# Serve al terminale nel browser: il server di tmux resta in piedi quando lo
# stream di "docker exec" muore, cosi' la sessione sopravvive al riavvio del
# gestore e alla riconnessione ci si riattacca invece di ricominciare.

USER root

# 1. tmux dai repository Debian gia' configurati nell'immagine.
#    Niente versione pinnata: il pacchetto stabile basta, e un repository in
#    piu' sarebbe un pezzo in piu' che si rompe per niente.
RUN apt-get update && apt-get install -y --no-install-recommends tmux \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# 2. Smoke test: fallisce la build se tmux non e' nel PATH.
#    "command -v tmux" e' la stessa domanda che il gestore fara' a runtime per
#    decidere se promettere che la sessione sopravvive.
RUN command -v tmux && tmux -V

USER node
$MARKER_END
"@

    # Forza LF ovunque -- Docker legge il file in Linux
    $combined = ($content.TrimEnd() + ($patch -replace "`r`n", "`n")) -replace "`r`n", "`n"
    [System.IO.File]::WriteAllText($DOCKERFILE, $combined)

    Write-Ok "Dockerfile patchato ($DOCKERFILE): tmux."
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
        Write-Ok "Nessun patch tmux trovato in $DOCKERFILE. Niente da rimuovere."
        return
    }

    $result = ($kept -join "`n").TrimEnd() + "`n"
    [System.IO.File]::WriteAllText($DOCKERFILE, $result)
    Write-Ok "Blocco patch tmux rimosso da $DOCKERFILE."
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

    Write-Host "  Patch tmux applicato : " -NoNewline -ForegroundColor DarkGray
    $content = [System.IO.File]::ReadAllText($DOCKERFILE)
    if ($content.Contains($MARKER_BEGIN)) {
        Write-Host "si'  (tmux dai repository Debian)" -ForegroundColor Green
    } else {
        Write-Host "no   (.\patch-dockerfile-tmux.ps1 patch)" -ForegroundColor Yellow
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

  patch-dockerfile-tmux.ps1 -- aggiunge tmux al Dockerfile claudebox

  USO
    .\patch-dockerfile-tmux.ps1 [comando]

  COMANDI
    patch    Aggiunge tmux (default, idempotente)
    remove   Rimuove il blocco patch
    status   Mostra lo stato corrente
    help     Mostra questo messaggio

  POSIZIONAMENTO CONSIGLIATO
    .devcontainer\patch-dockerfile-tmux.ps1
    -> claudebox lo esegue automaticamente dopo init/update e prima di up.

  VARIABILI AMBIENTE
    DOCKERFILE   Path al Dockerfile (override auto-discovery)

  WORKFLOW AUTOMATICO
    Copy-Item patch-dockerfile-tmux.ps1 .devcontainer\
    claudebox start -y

  COSA OTTIENI NEL CONTAINER
    tmux       Il terminale che il gestore apre dal browser gira dentro una
               sessione di tmux, e la sessione resta anche quando il gestore si
               riavvia: alla riconnessione ci si riattacca invece di
               ricominciare. Su un container senza tmux il terminale funziona
               lo stesso, ma la pagina dichiara che la sessione non
               sopravvivera' al riavvio.

"@ -ForegroundColor White
}

# ── Entry point ────────────────────────────────────────────────────────────────
switch ($Command) {
    'remove' { Invoke-Remove }
    'status' { Show-Status  }
    'help'   { Show-Help    }
    default  { Invoke-Patch }   # '' o 'patch'
}
