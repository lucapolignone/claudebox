#Requires -Version 5.1
<#
.SYNOPSIS
    claudebox -- devcontainer Claude Code per la cartella corrente (auto-installante)

.DESCRIPTION
    Al primo avvio senza argomenti, o con il flag -Install, lo script si copia
    in un percorso nel PATH dell'utente e aggiunge un alias "claudebox" al profilo
    PowerShell, cosi da essere richiamabile da qualsiasi cartella.

.PARAMETER Command
    Comando da eseguire: install | init | up | start | shell | stop | destroy | help

.EXAMPLE
    # Prima esecuzione -- auto-installazione:
    .\claudebox.ps1

    # Dopo l'installazione, da qualsiasi cartella:
    claudebox init
    claudebox up
    claudebox shell
    claudebox stop
    claudebox destroy
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('install','init','up','start','update','shell','stop','destroy','help','')]
    [string]$Command = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Colori / output helpers ---------------------------------------------------
function Write-Info    ($msg) { Write-Host "  $([char]0x25B8) $msg" -ForegroundColor Cyan    }
function Write-Ok      ($msg) { Write-Host "  $([char]0x2714) $msg" -ForegroundColor Green   }
function Write-Warn    ($msg) { Write-Host "  $([char]0x26A0) $msg" -ForegroundColor Yellow  }
function Write-Err     ($msg) { Write-Host "  $([char]0x2716) $msg" -ForegroundColor Red; exit 1 }
function Write-Header  ($msg) { Write-Host "`n$msg" -ForegroundColor Blue -NoNewline
                                 Write-Host "" }

# --- Helpers -------------------------------------------------------------------
function Get-ProjectName {
    (Split-Path -Leaf (Get-Location)) `
        -replace '[^a-zA-Z0-9_\-]', '-' `
        -replace '-+', '-' |
        ForEach-Object { $_.ToLower().Trim('-') }
}

function Get-ContainerName { "claudebox-$(Get-ProjectName)" }

function Test-ContainerExists {
    $name = Get-ContainerName
    $result = docker ps -a --format '{{.Names}}' 2>$null | Where-Object { $_ -eq $name }
    return [bool]$result
}

function Test-ContainerRunning {
    $name = Get-ContainerName
    $result = docker ps --format '{{.Names}}' 2>$null | Where-Object { $_ -eq $name }
    return [bool]$result
}

# --- Percorso di installazione -------------------------------------------------
function Get-InstallDir {
    # Primo percorso utente gia nel PATH, altrimenti ne creiamo uno dedicato
    $candidates = @(
        "$env:USERPROFILE\bin",
        "$env:USERPROFILE\.local\bin",
        "$env:APPDATA\PowerShell\Scripts"
    )
    foreach ($dir in $candidates) {
        if (Test-Path $dir) { return $dir }
    }
    # Nessuno trovato: creiamo il primo
    New-Item -ItemType Directory -Path $candidates[0] -Force | Out-Null
    return $candidates[0]
}

# --- AUTO-INSTALLAZIONE --------------------------------------------------------
function Invoke-Install {
    Write-Header "=== Installazione claudebox ==="

    $installDir  = Get-InstallDir
    $destScript  = Join-Path $installDir 'claudebox.ps1'
    $sourceScript = $MyInvocation.PSCommandPath

    # 1. Copia lo script
    Write-Info "Copia script in: $destScript"
    Copy-Item -Path $sourceScript -Destination $destScript -Force
    Write-Ok "Script copiato"

    # 2. Aggiunge la directory al PATH utente (se non c'e gia)
    $currentPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
    if ($currentPath -notlike "*$installDir*") {
        [Environment]::SetEnvironmentVariable(
            'PATH', "$currentPath;$installDir", 'User')
        $env:PATH = "$env:PATH;$installDir"
        Write-Ok "Aggiunto al PATH utente: $installDir"
    } else {
        Write-Info "$installDir gia nel PATH"
    }

    # 3. Aggiunge alias "claudebox" al profilo PowerShell
    $profilePath = $PROFILE.CurrentUserAllHosts
    $profileDir  = Split-Path $profilePath
    if (-not (Test-Path $profileDir)) {
        New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
    }
    if (-not (Test-Path $profilePath)) {
        New-Item -ItemType File -Path $profilePath -Force | Out-Null
    }

    $aliasLine = "function claudebox { & '$destScript' @args }"
    $profileContent = Get-Content $profilePath -Raw -ErrorAction SilentlyContinue
    if ($profileContent -notlike "*claudebox*") {
        Add-Content -Path $profilePath -Value "`n# claudebox alias (aggiunto da claudebox.ps1)`n$aliasLine"
        Write-Ok "Alias 'claudebox' aggiunto al profilo: $profilePath"
    } else {
        Write-Info "Alias 'claudebox' gia presente nel profilo"
    }

    # 4. Carica subito l'alias nella sessione corrente
    Invoke-Expression $aliasLine

    Write-Host ""
    Write-Ok "Installazione completata!"
    Write-Host ""
    Write-Host "  Riavvia PowerShell (o esegui: . `$PROFILE) per usare" -ForegroundColor White
    Write-Host "  il comando 'claudebox' da qualsiasi cartella." -ForegroundColor White
    Write-Host ""
    Write-Host "  Uso rapido:" -ForegroundColor White
    Write-Host "    cd C:\tuoi\progetti\mio-progetto" -ForegroundColor DarkGray
    Write-Host "    claudebox init" -ForegroundColor DarkGray
    Write-Host "    claudebox up" -ForegroundColor DarkGray
    Write-Host ""
}

# --- PREREQUISITI --------------------------------------------------------------
function Test-Prerequisites {
    Write-Header "=== Controllo prerequisiti ==="

    # Docker CLI
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Write-Err "Docker non trovato. Installalo da https://www.docker.com/products/docker-desktop"
    }
    Write-Ok "Docker trovato: $(docker --version)"

    # Daemon Docker
    try {
        docker info 2>&1 | Out-Null
        Write-Ok "Docker daemon attivo"
    } catch {
        Write-Err "Il daemon Docker non risponde. Avvia Docker Desktop e riprova."
    }

    # CLAUDE_CONFIG_DIR
    if (-not $env:CLAUDE_CONFIG_DIR) {
        $candidates = @(
            "$env:USERPROFILE\.claude",
            "$env:APPDATA\claude",
            "$env:USERPROFILE\.config\claude"
        )
        foreach ($c in $candidates) {
            if (Test-Path $c) {
                $env:CLAUDE_CONFIG_DIR = $c
                Write-Warn "CLAUDE_CONFIG_DIR non impostata; uso: $c"
                break
            }
        }
        if (-not $env:CLAUDE_CONFIG_DIR) {
            Write-Err (@"
CLAUDE_CONFIG_DIR non impostata e nessuna cartella Claude trovata.
Imposta la variabile prima di usare questo comando:
  `$env:CLAUDE_CONFIG_DIR = "`$env:USERPROFILE\.claude"
O in modo permanente:
  [Environment]::SetEnvironmentVariable('CLAUDE_CONFIG_DIR', "`$env:USERPROFILE\.claude", 'User')
"@)
        }
    }

    if (-not (Test-Path $env:CLAUDE_CONFIG_DIR)) {
        Write-Err "CLAUDE_CONFIG_DIR='$env:CLAUDE_CONFIG_DIR' non esiste."
    }
    Write-Ok "CLAUDE_CONFIG_DIR -> $env:CLAUDE_CONFIG_DIR"

    # CCSTATUSLINE_CONFIG_DIR
    if (-not $env:CCSTATUSLINE_CONFIG_DIR) {
        $ccDefault = "$env:USERPROFILE\.config\ccstatusline"
        if (Test-Path $ccDefault) {
            $env:CCSTATUSLINE_CONFIG_DIR = $ccDefault
            Write-Warn "CCSTATUSLINE_CONFIG_DIR non impostata; uso: $ccDefault"
        } else {
            Write-Warn "CCSTATUSLINE_CONFIG_DIR non impostata e $ccDefault non trovata. ccstatusline non sara configurato."
            $env:CCSTATUSLINE_CONFIG_DIR = $ccDefault
        }
    }
    Write-Ok "CCSTATUSLINE_CONFIG_DIR -> $env:CCSTATUSLINE_CONFIG_DIR"
}

# --- INIT ----------------------------------------------------------------------
# URL base dei file ufficiali Anthropic su GitHub (raw)
$ANTHROPIC_RAW_BASE = 'https://raw.githubusercontent.com/anthropics/claude-code/main/.devcontainer'

function Invoke-Download {
    param(
        [string]$Url,
        [string]$Dest,
        [string]$Label
    )
    Write-Info "Download $Label..."
    try {
        # Scarica come byte per preservare i line ending originali (LF su Linux)
        $bytes = (Invoke-WebRequest -Uri $Url -UseBasicParsing -ErrorAction Stop).Content
        # Content puo essere string o byte[] a seconda della versione di PS
        if ($bytes -is [string]) {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($bytes)
        }
        [System.IO.File]::WriteAllBytes($Dest, $bytes)
        Write-Ok "$Label scaricato da GitHub ufficiale"
    } catch {
        Write-Err "Impossibile scaricare $Label da:`n  $Url`nErrore: $_`nVerifica la connessione a internet e riprova."
    }
}

function Invoke-Init {
    $proj  = Get-ProjectName
    $dcDir = Join-Path (Get-Location) ".devcontainer"

    Write-Header "=== Inizializzazione devcontainer per '$proj' ==="

    if (Test-Path $dcDir) {
        Write-Warn "La cartella $dcDir esiste gia."
        $answer = Read-Host "Sovrascrivere i file? [y/N]"
        if ($answer.ToLower() -ne 'y') { Write-Info "Annullato."; return }
    }
    New-Item -ItemType Directory -Path $dcDir -Force | Out-Null

    # -- Dockerfile e init-firewall.sh: scaricati direttamente da Anthropic ----
    Write-Info "Scarico i file ufficiali da anthropics/claude-code..."
    Invoke-Download `
        -Url  "$ANTHROPIC_RAW_BASE/Dockerfile" `
        -Dest "$dcDir\Dockerfile" `
        -Label "Dockerfile"

    Invoke-Download `
        -Url  "$ANTHROPIC_RAW_BASE/init-firewall.sh" `
        -Dest "$dcDir\init-firewall.sh" `
        -Label "init-firewall.sh"

    # -- devcontainer.json: generato da noi con le personalizzazioni -----------
    # Differenze rispetto all'originale Anthropic:
    #   - "name" impostato al nome del progetto corrente
    #   - CLAUDE_CONFIG_DIR dell'host -> /host-claude (read-only, mai modificata)
    #   - volume Docker condiviso "claudebox-shared-config" -> /home/node/.claude
    #     (filesystem Linux nativo: niente problemi di rename/atomic ops su NTFS)
    #     Al primo avvio copia automaticamente le credenziali da /host-claude
    #   - volume history per progetto per evitare conflitti tra progetti
    Write-Info "Genero devcontainer.json personalizzato..."
    $devcontainerJson = @"
{
  "name": "$proj",
  "build": {
    "dockerfile": "Dockerfile"
  },
  "workspaceFolder": "/workspace",
  "workspaceMount": "source=`${localWorkspaceFolder},target=/workspace,type=bind,consistency=cached",
  "mounts": [
    "source=`${localEnv:CLAUDE_CONFIG_DIR},target=/host-claude,type=bind,readonly=true,consistency=cached",
    "source=`${localEnv:CCSTATUSLINE_CONFIG_DIR},target=/host-ccstatusline,type=bind,readonly=true,consistency=cached",
    "source=claudebox-shared-config,target=/home/node/.claude,type=volume",
    "source=claudebox-shared-ccstatusline,target=/home/node/.config/ccstatusline,type=volume",
    "source=claudebox-$proj-history,target=/commandhistory,type=volume"
  ],
  "remoteUser": "node",
  "containerEnv": {
    "CLAUDE_CONFIG_DIR": "/home/node/.claude",
    "CCSTATUSLINE_CONFIG_DIR": "/home/node/.config/ccstatusline",
    "NODE_OPTIONS": "--max-old-space-size=4096",
    "DEVCONTAINER": "true",
    "PATH": "/home/node/.local/bin:/usr/local/share/npm-global/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  },
  "runArgs": [
    "--cap-add=NET_ADMIN",
    "--cap-add=NET_RAW"
  ],
  "postStartCommand": "sudo chown -R node:node /home/node/.claude /home/node/.config && mkdir -p /home/node/.local/bin /home/node/.config/ccstatusline && if [ ! -f /home/node/.claude/.credentials.json ]; then cp -rn /host-claude/. /home/node/.claude/ 2>/dev/null || true; fi && if [ ! -f /home/node/.config/ccstatusline/settings.json ]; then cp -rn /host-ccstatusline/. /home/node/.config/ccstatusline/ 2>/dev/null || true; fi && sudo /usr/local/bin/init-firewall.sh 2>/dev/null || true",
  "customizations": {
    "vscode": {
      "extensions": [
        "anthropic.claude-code",
        "dbaeumer.vscode-eslint",
        "esbenp.prettier-vscode",
        "eamodio.gitlens"
      ],
      "settings": {
        "editor.formatOnSave": true,
        "editor.defaultFormatter": "esbenp.prettier-vscode",
        "terminal.integrated.defaultProfile.linux": "zsh"
      }
    }
  }
}
"@
    # Scrivi con LF (compatibilita cross-platform)
    $jsonLf    = $devcontainerJson -replace "`r`n", "`n"
    $jsonBytes = [System.Text.Encoding]::UTF8.GetBytes($jsonLf)
    $jsonPath  = Join-Path $dcDir "devcontainer.json"
    [System.IO.File]::WriteAllBytes($jsonPath, $jsonBytes)

    Write-Ok "Generato $dcDir\devcontainer.json (personalizzato)"
    Write-Host ""
    Write-Host "  File nella cartella .devcontainer:" -ForegroundColor DarkGray
    Write-Host "    Dockerfile        <- ufficiale anthropics/claude-code" -ForegroundColor DarkGray
    Write-Host "    init-firewall.sh  <- ufficiale anthropics/claude-code" -ForegroundColor DarkGray
    Write-Host "    devcontainer.json <- personalizzato (nome progetto + mount config)" -ForegroundColor DarkGray
    Write-Host ""
    Write-Info "Prossimo passo: claudebox up"
}

# --- UP ------------------------------------------------------------------------
function Invoke-Up {
    Test-Prerequisites

    if (-not (Test-Path ".devcontainer\devcontainer.json")) {
        Write-Err "Nessun .devcontainer trovato. Esegui prima: claudebox init"
    }

    $proj  = Get-ProjectName
    $cname = Get-ContainerName
    $pwd   = (Get-Location).Path

    # Normalizza il percorso per Docker (converte backslash -> slash e C: -> /c)
    # Converte C:\foo\bar -> /c/foo/bar (scriptblock -replace non funziona in PS 5.x)
    function Convert-ToDockerPath([string]$winPath) {
        $p = $winPath -replace '\\', '/'
        if ($p -match '^([A-Za-z]):(.*)') {
            return '/' + $Matches[1].ToLower() + $Matches[2]
        }
        return $p
    }
    $dockerWorkspace        = Convert-ToDockerPath $pwd
    $dockerConfigDir        = Convert-ToDockerPath $env:CLAUDE_CONFIG_DIR
    $dockerCcstatuslineDir  = Convert-ToDockerPath $env:CCSTATUSLINE_CONFIG_DIR

    Write-Header "=== Avvio devcontainer '$proj' ==="

    # -- Build ------------------------------------------------------------------
    Write-Info "Build immagine Docker (qualche minuto alla prima esecuzione)..."
    docker build -t "claudebox-img-$proj" .devcontainer
    Write-Ok "Immagine pronta: claudebox-img-$proj"

    # -- Verifica accesso Docker alla CLAUDE_CONFIG_DIR -------------------------
    Write-Info "Verifica che Docker possa accedere a CLAUDE_CONFIG_DIR..."
    $probeOutput = & docker run --rm `
        -v "${dockerConfigDir}:/probe:ro" `
        "claudebox-img-$proj" `
        ls /probe 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host ""
        Write-Host "  ERR Docker non riesce ad accedere alla cartella:" -ForegroundColor Red
        Write-Host "      $env:CLAUDE_CONFIG_DIR" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  Devi aggiungerla al File Sharing di Docker Desktop:" -ForegroundColor White
        Write-Host ""
        Write-Host "    1. Apri Docker Desktop" -ForegroundColor DarkGray
        Write-Host "    2. Vai in Settings -> Resources -> File Sharing" -ForegroundColor DarkGray
        Write-Host "    3. Aggiungi questo percorso:" -ForegroundColor DarkGray
        Write-Host "       $env:CLAUDE_CONFIG_DIR" -ForegroundColor Cyan
        Write-Host "    4. Clicca Apply & Restart" -ForegroundColor DarkGray
        Write-Host "    5. Riesegui: claudebox up" -ForegroundColor DarkGray
        Write-Host ""
        exit 1
    }
    Write-Ok "Docker ha accesso a CLAUDE_CONFIG_DIR"

    # Probe anche per ccstatusline (opzionale - non blocca se manca)
    if ($env:CCSTATUSLINE_CONFIG_DIR -and (Test-Path $env:CCSTATUSLINE_CONFIG_DIR)) {
        $probeCs = & docker run --rm `
            -v "${dockerCcstatuslineDir}:/probe-cs:ro" `
            "claudebox-img-$proj" `
            ls /probe-cs 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Warn "Docker non riesce ad accedere a CCSTATUSLINE_CONFIG_DIR ($env:CCSTATUSLINE_CONFIG_DIR)."
            Write-Host "  Aggiungila in Docker Desktop -> Settings -> Resources -> File Sharing" -ForegroundColor DarkGray
            Write-Host "  ccstatusline procedera senza config personalizzata." -ForegroundColor DarkGray
        } else {
            Write-Ok "Docker ha accesso a CCSTATUSLINE_CONFIG_DIR"
        }
    }

    # -- Rimuovi container precedente -------------------------------------------
    if (Test-ContainerExists) {
        Write-Info "Rimozione container precedente '$cname'..."
        docker rm -f $cname | Out-Null
    }

    # -- Avvia container --------------------------------------------------------
    Write-Info "Avvio container '$cname'..."
    docker run -d `
        --name $cname `
        --cap-add=NET_ADMIN `
        --cap-add=NET_RAW `
        -v "${dockerWorkspace}:/workspace:cached" `
        -v "${dockerConfigDir}:/host-claude:ro" `
        -v "${dockerCcstatuslineDir}:/host-ccstatusline:ro" `
        -v "claudebox-shared-config:/home/node/.claude" `
        -v "claudebox-shared-ccstatusline:/home/node/.config/ccstatusline" `
        -v "claudebox-${proj}-history:/commandhistory" `
        -e CLAUDE_CONFIG_DIR="/home/node/.claude" `
        -e CCSTATUSLINE_CONFIG_DIR="/home/node/.config/ccstatusline" `
        -w /workspace `
        "claudebox-img-$proj" `
        sleep infinity | Out-Null
    Write-Ok "Container avviato"

    # -- Firewall ---------------------------------------------------------------
    Write-Info "Inizializzazione firewall..."
    try {
        # Copia config dall host al volume condiviso se e il primo avvio
        docker exec $cname bash -c 'if [ ! -f /home/node/.claude/.credentials.json ]; then cp -rn /host-claude/. /home/node/.claude/ 2>/dev/null || true; fi' | Out-Null
        # Copia config ccstatusline al primo avvio
        docker exec $cname bash -c 'mkdir -p /home/node/.config/ccstatusline && if [ ! -f /home/node/.config/ccstatusline/settings.json ]; then cp -rn /host-ccstatusline/. /home/node/.config/ccstatusline/ 2>/dev/null || true; fi' | Out-Null
        # Fix path Windows -> Linux nei JSON di configurazione di Claude Code
        # Agisce solo sui file noti che contengono path (NON .claude.json che e testo libero)
        docker exec -u node $cname node -e @'
const fs = require("fs");
const path = require("path");

const CLAUDE_DIR = "/home/node/.claude";

// Lista esplicita dei file/cartelle che possono contenere path Windows
// .claude.json escluso: contiene testo libero (memoria, istruzioni) che puo
// contenere sequenze tipo C:\ per caso, non path reali da fixare
const TARGET_DIRS = [
  "plugins",
  "ide",
  "config",
];

const WIN_PATH_RE = /[A-Za-z]:[\\\/][^"
]*/g;

function fixValue(str) {
  return str.replace(WIN_PATH_RE, match => {
    let p = match.replace(/\\/g, "/");
    p = p.replace(/^[A-Za-z]:\/.*?\.claude/, CLAUDE_DIR);
    return p;
  });
}

function fixJsonFile(filePath) {
  try {
    const raw = fs.readFileSync(filePath, "utf8");
    WIN_PATH_RE.lastIndex = 0;
    if (!WIN_PATH_RE.test(raw)) return;
    WIN_PATH_RE.lastIndex = 0;
    const fixed = fixValue(raw);
    if (fixed !== raw) {
      fs.writeFileSync(filePath, fixed, "utf8");
      process.stdout.write("Fixed: " + filePath + "\n");
    }
  } catch (e) {}
}

function walk(dir) {
  let entries;
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); }
  catch (e) { return; }
  for (const entry of entries) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) walk(full);
    else if (entry.isFile() && entry.name.endsWith(".json")) fixJsonFile(full);
  }
}

for (const dir of TARGET_DIRS) {
  walk(path.join(CLAUDE_DIR, dir));
}
'@ 2>$null | Out-Null
        docker exec $cname sudo /usr/local/bin/init-firewall.sh 2>&1 | Out-Null
        Write-Ok "Firewall applicato"
    } catch {
        Write-Warn "Firewall non applicato (NET_ADMIN potrebbe non essere disponibile)."
    }

    # -- Verifica isolamento ----------------------------------------------------
    Write-Header "=== Verifica isolamento container ==="
    $workdir = docker exec -u node $cname pwd
    if ($workdir.Trim() -eq '/workspace') {
        Write-Ok "Isolamento confermato: pwd = /workspace"
    } else {
        Write-Err "Isolamento NON verificato: pwd = '$workdir' (atteso /workspace)"
    }

    # -- Lancio Claude Code interattivo -----------------------------------------
    Write-Header "=== Avvio Claude Code (--dangerously-skip-permissions) ==="
    Write-Host "  Il container e' pronto. Lancio Claude Code..." -ForegroundColor Yellow
    Write-Host "  Digita 'exit' per uscire dalla shell del container.`n" -ForegroundColor Yellow

    docker exec -it -u node $cname zsh -c 'claude --dangerously-skip-permissions; exec zsh'
}

# --- UPDATE: ri-scarica Dockerfile e init-firewall.sh da Anthropic ------------
function Invoke-Update {
    $dcDir = Join-Path (Get-Location) ".devcontainer"

    Write-Header "=== Aggiornamento file ufficiali Anthropic ==="

    if (-not (Test-Path $dcDir)) {
        Write-Err "Nessun .devcontainer trovato. Esegui prima: claudebox init"
    }

    Write-Info "Scarico versioni aggiornate da anthropics/claude-code (main)..."
    Invoke-Download `
        -Url  "$ANTHROPIC_RAW_BASE/Dockerfile" `
        -Dest "$dcDir\Dockerfile" `
        -Label "Dockerfile"

    Invoke-Download `
        -Url  "$ANTHROPIC_RAW_BASE/init-firewall.sh" `
        -Dest "$dcDir\init-firewall.sh" `
        -Label "init-firewall.sh"

    Write-Host ""
    Write-Ok "File ufficiali aggiornati. devcontainer.json non modificato."
    Write-Info "Esegui 'claudebox up' per ricostruire l'immagine con le modifiche."
}

# --- START: init + up in un solo comando --------------------------------------
function Invoke-Start {
    $proj  = Get-ProjectName
    $dcDir = Join-Path (Get-Location) ".devcontainer"

    # -- Banner -----------------------------------------------------------------
    Write-Host ""
    Write-Host "  +======================================================+" -ForegroundColor Blue
    Write-Host "  |         claudebox  --  avvio automatico              |" -ForegroundColor Blue
    Write-Host "  +======================================================+" -ForegroundColor Blue
    Write-Host ""
    Write-Host "  Progetto : " -NoNewline -ForegroundColor DarkGray
    Write-Host $proj -ForegroundColor White
    Write-Host "  Cartella : " -NoNewline -ForegroundColor DarkGray
    Write-Host (Get-Location).Path -ForegroundColor White

    # -- Risolvi CLAUDE_CONFIG_DIR prima del riepilogo --------------------------
    if (-not $env:CLAUDE_CONFIG_DIR) {
        $candidates = @(
            "$env:USERPROFILE\.claude",
            "$env:APPDATA\claude",
            "$env:USERPROFILE\.config\claude"
        )
        foreach ($c in $candidates) {
            if (Test-Path $c) { $env:CLAUDE_CONFIG_DIR = $c; break }
        }
    }

    # Se ancora non trovata, chiedi interattivamente
    if (-not $env:CLAUDE_CONFIG_DIR -or -not (Test-Path $env:CLAUDE_CONFIG_DIR)) {
        Write-Host ""
        Write-Warn "CLAUDE_CONFIG_DIR non configurata o non trovata automaticamente."
        Write-Host ""
        Write-Host "  Claude Code salva credenziali e configurazioni in una cartella dedicata." -ForegroundColor DarkGray
        Write-Host "  Di solito si trova in: $env:USERPROFILE\.claude" -ForegroundColor DarkGray
        Write-Host ""
        $inputDir = Read-Host "  Inserisci il percorso della config Claude (Invio per default: $env:USERPROFILE\.claude)"
        if ([string]::IsNullOrWhiteSpace($inputDir)) {
            $inputDir = "$env:USERPROFILE\.claude"
        }
        # Crea la cartella se non esiste (primo avvio di Claude Code)
        if (-not (Test-Path $inputDir)) {
            Write-Warn "La cartella '$inputDir' non esiste. La creo ora (verra' popolata da Claude Code al primo avvio)."
            New-Item -ItemType Directory -Path $inputDir -Force | Out-Null
        }
        $env:CLAUDE_CONFIG_DIR = $inputDir
        # Salva in modo permanente per le sessioni future
        [Environment]::SetEnvironmentVariable('CLAUDE_CONFIG_DIR', $inputDir, 'User')
        Write-Ok "CLAUDE_CONFIG_DIR impostata permanentemente: $inputDir"
    }

    Write-Host "  Config   : " -NoNewline -ForegroundColor DarkGray
    Write-Host $env:CLAUDE_CONFIG_DIR -ForegroundColor White
    Write-Host "  ccstatus : " -NoNewline -ForegroundColor DarkGray
    if ($env:CCSTATUSLINE_CONFIG_DIR -and (Test-Path $env:CCSTATUSLINE_CONFIG_DIR)) {
        Write-Host $env:CCSTATUSLINE_CONFIG_DIR -ForegroundColor White
    } else {
        Write-Host "(non trovata, verra saltata)" -ForegroundColor DarkGray
    }

    # -- Stato attuale ----------------------------------------------------------
    $hasDevcontainer = Test-Path "$dcDir\devcontainer.json"
    $containerExists = Test-ContainerExists
    $containerRunning = Test-ContainerRunning

    # Decidiamo qui se fare update, cosi lo includiamo nel riepilogo passi
    $doUpdate = $false
    if ($hasDevcontainer) {
        Write-Host ""
        Write-Host "  +- Dockerfile e init-firewall.sh potrebbero essere datati." -ForegroundColor DarkGray
        Write-Host "  |  Aggiornare i file ufficiali da Anthropic prima di avviare?" -ForegroundColor DarkGray
        $updateAnswer = Read-Host "  +- Update? [y/N]"
        $doUpdate = $updateAnswer.ToLower() -eq 'y'
    }

    Write-Host ""
    Write-Host "  Stato attuale:" -ForegroundColor DarkGray
    Write-Host "    .devcontainer : " -NoNewline -ForegroundColor DarkGray
    if ($hasDevcontainer) {
        Write-Host "presente" -ForegroundColor Green
    } else {
        Write-Host "assente  -> verra' creato" -ForegroundColor Yellow
    }
    Write-Host "    Container     : " -NoNewline -ForegroundColor DarkGray
    if ($containerRunning) {
        Write-Host "in esecuzione -> verra' ricreato" -ForegroundColor Yellow
    } elseif ($containerExists) {
        Write-Host "fermo     -> verra' ricreato" -ForegroundColor Yellow
    } else {
        Write-Host "assente   -> verra' creato" -ForegroundColor Yellow
    }

    # Calcola la numerazione dei passi dinamicamente
    $step = 1
    Write-Host ""
    Write-Host "  Passi che verranno eseguiti:" -ForegroundColor DarkGray
    if (-not $hasDevcontainer) {
        Write-Host "    $step. init   -- scarica file ufficiali Anthropic e genera devcontainer.json" -ForegroundColor DarkGray
        $step++
    } elseif ($doUpdate) {
        Write-Host "    $step. update -- ri-scarica Dockerfile e init-firewall.sh da Anthropic" -ForegroundColor DarkGray
        $step++
    }
    Write-Host "    $step. build  -- costruisce l'immagine Docker" -ForegroundColor DarkGray; $step++
    Write-Host "    $step. run    -- avvia il container e monta le cartelle" -ForegroundColor DarkGray; $step++
    Write-Host "    $step. check  -- verifica isolamento (pwd = /workspace)" -ForegroundColor DarkGray; $step++
    Write-Host "    $step. claude -- lancia claude --dangerously-skip-permissions" -ForegroundColor DarkGray
    Write-Host ""

    $confirm = Read-Host "  Avviare? [Y/n]"
    if ($confirm.ToLower() -eq 'n') { Write-Info "Annullato."; return }

    # -- Step: init o update ----------------------------------------------------
    if (-not $hasDevcontainer) {
        Write-Host ""
        Write-Header "=== Init devcontainer ==="
        Invoke-Init
    } elseif ($doUpdate) {
        Write-Host ""
        Write-Header "=== Update file ufficiali Anthropic ==="
        Invoke-Update
    } else {
        Write-Host ""
        Write-Ok "Uso configurazione esistente in $dcDir\ (nessun update richiesto)"
    }

    # -- Up: build + run + verifica + claude ------------------------------------
    Write-Host ""
    Invoke-Up
}

# --- SHELL ---------------------------------------------------------------------
function Invoke-Shell {
    $cname = Get-ContainerName
    if (-not (Test-ContainerRunning)) {
        Write-Err "Container '$cname' non in esecuzione. Usa: claudebox up"
    }
    Write-Info "Apertura shell in '$cname'..."
    docker exec -it -u node $cname zsh
}

# --- STOP ----------------------------------------------------------------------
function Invoke-Stop {
    $cname = Get-ContainerName
    if (-not (Test-ContainerRunning)) { Write-Info "Container non in esecuzione."; return }
    docker stop $cname | Out-Null
    Write-Ok "Container '$cname' fermato."
}

# --- DESTROY -------------------------------------------------------------------
function Invoke-Destroy {
    $proj  = Get-ProjectName
    $cname = Get-ContainerName
    Write-Warn "Questa operazione rimuove container, volume history e immagine per '$proj'."
    Write-Host "  Il volume condiviso 'claudebox-shared-config' NON viene rimosso (condiviso tra progetti)." -ForegroundColor DarkGray
    $answer = Read-Host "Continuare? [y/N]"
    if ($answer.ToLower() -ne 'y') { Write-Info "Annullato."; return }

    if (Test-ContainerExists) {
        docker rm -f $cname | Out-Null
        Write-Ok "Container rimosso"
    }
    docker volume rm "claudebox-${proj}-history" 2>$null | Out-Null
    Write-Ok "Volume history rimosso (se esisteva)"
    docker rmi "claudebox-img-$proj" 2>$null | Out-Null
    Write-Ok "Immagine rimossa (se esisteva)"

    Write-Host ""
    Write-Host "  Per rimuovere anche il volume config condiviso (credenziali e impostazioni Claude):" -ForegroundColor DarkGray
    Write-Host "    docker volume rm claudebox-shared-config" -ForegroundColor DarkGray
}

# --- HELP ----------------------------------------------------------------------
function Show-Help {
    Write-Host @"

  claudebox -- devcontainer Claude Code per la cartella corrente

  USO
    claudebox <comando>

  COMANDI
    install   Auto-installa lo script nel PATH e crea l'alias nel profilo PS
    start     Esegue tutto in automatico: init (se serve) + build + run + claude
    init      Scarica Dockerfile e init-firewall.sh da Anthropic, genera devcontainer.json
    update    Ri-scarica Dockerfile e init-firewall.sh da Anthropic (senza toccare devcontainer.json)
    up        Build immagine, avvio container, verifica isolamento, lancia claude
    shell     Apre una shell nel container gia' avviato
    stop      Ferma il container (senza rimuoverlo)
    destroy   Rimuove container, volume history e immagine

  VARIABILI D'AMBIENTE
    CLAUDE_CONFIG_DIR   Percorso della config Claude Code
                        (default: ~\.claude se esiste)

  PRIMA ESECUZIONE
    # Scarica e installa (una tantum):
    .\claudebox.ps1

    # Poi da qualsiasi cartella progetto -- tutto in un comando:
    cd C:\progetti\mio-progetto
    claudebox start

    # Oppure passo-passo:
    claudebox init
    claudebox up

"@ -ForegroundColor White
}

# --- ENTRY POINT ---------------------------------------------------------------
# Se eseguito senza argomenti per la prima volta, avvia l'installazione
if ($Command -eq '' -or $Command -eq 'install') {
    Invoke-Install
    exit 0
}

switch ($Command) {
    'init'    { Invoke-Init    }
    'up'      { Invoke-Up      }
    'start'   { Invoke-Start   }
    'update'  { Invoke-Update  }
    'shell'   { Invoke-Shell   }
    'stop'    { Invoke-Stop    }
    'destroy' { Invoke-Destroy }
    default   { Show-Help      }
}
