#Requires -Version 5.1
<#
.SYNOPSIS
    claudebox -- isolated Claude Code devcontainer for the current project folder (self-installing)

.DESCRIPTION
    On first run without arguments the script copies itself into a PATH directory
    and adds a "claudebox" function to the PowerShell profile,
    making it available from any folder.

.PARAMETER Command
    Command to run: install | init | up | start | update | shell | stop | destroy | help

.PARAMETER AutoYes
    Skip all confirmation prompts (equivalent to answering Y/yes to everything)

.EXAMPLE
    # First run -- self-install:
    .\claudebox.ps1

    # After installation, from any folder:
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
    [string]$Command = '',

    [Parameter()]
    [Alias('y')]
    [switch]$AutoYes,

    [Parameter()]
    [Alias('p')]
    [string]$Profile = 'personal',

    [Parameter()]
    [Alias('n')]
    [switch]$NoUpdate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Confirm-Step ($prompt) {
    if ($AutoYes) { return $true }
    $r = Read-Host $prompt
    return ($r.ToLower() -ne 'n')
}

function Read-InputOrDefault ($prompt, $default) {
    if ($AutoYes) { Write-Host "$prompt [auto: $default]"; return $default }
    $r = Read-Host $prompt
    if ([string]::IsNullOrWhiteSpace($r)) { return $default }
    return $r
}

# --- Profile resolution --------------------------------------------------------
function Resolve-Profile ([string]$prof) {
    if ($prof -eq 'personal' -or $prof -eq '') { return "$env:USERPROFILE\.claude" }
    return "$env:USERPROFILE\.claude-$prof"
}
function Get-VolumeSuffix ([string]$prof) {
    if ($prof -eq 'personal' -or $prof -eq '') { return 'personal' }
    return $prof
}

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

# Il nome del container include il profilo (tranne 'personal', per retrocompatibilità)
function Get-ContainerName {
    $base = "claudebox-$(Get-ProjectName)"
    if ($Profile -ne 'personal' -and $Profile -ne '') {
        return "$base-$Profile"
    }
    return $base
}

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

# --- Version pinning: rende la cache di Docker consapevole della versione di CC
# Strategia: scarichiamo il Dockerfile ufficiale da Anthropic, poi sostituiamo
# `@anthropic-ai/claude-code` con `@anthropic-ai/claude-code@<latest>` usando la
# versione corrente dal registry npm. Risultato:
#   - versione invariata -> file identico -> cache Docker hit -> build istantanea
#   - versione nuova      -> riga RUN diversa -> cache invalidata da quel layer
#     in poi, rebuild solo degli step che dipendono da CC (non da zero)
function Get-LatestClaudeCodeVersion {
    try {
        $resp = Invoke-RestMethod `
            -Uri 'https://registry.npmjs.org/@anthropic-ai/claude-code/latest' `
            -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
        if ($resp -and $resp.version) { return [string]$resp.version }
    } catch { }
    return $null
}

function Update-DockerfileClaudeVersion {
    param(
        [Parameter(Mandatory)][string]$DockerfilePath,
        [Parameter(Mandatory)][string]$Version
    )
    if (-not (Test-Path -LiteralPath $DockerfilePath)) { return $false }
    $content = [System.IO.File]::ReadAllText($DockerfilePath)
    # Il Dockerfile ufficiale Anthropic usa `@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}`
    # (interpolazione ARG/ENV). La char class deve accettare anche $, {, } e qualsiasi
    # altro carattere non-whitespace/non-shell-operator, altrimenti il gruppo opzionale
    # fallisce e lasciamo la riga in uno stato rotto (doppio tag: @2.1.112@${VAR}).
    $patched = [regex]::Replace(
        $content,
        '@anthropic-ai/claude-code(@[^\s;&|]*)?',
        "@anthropic-ai/claude-code@$Version"
    )
    if ($patched -ne $content) {
        # Preserva line endings LF (il file viene eseguito in Linux container)
        $patched = $patched -replace "`r`n", "`n"
        [System.IO.File]::WriteAllText($DockerfilePath, $patched)
        return $true
    }
    return $false
}

# --- Percorso di installazione -------------------------------------------------
function Get-InstallDir {
    # Use first existing user directory in PATH, otherwise create one
    $candidates = @(
        "$env:USERPROFILE\bin",
        "$env:USERPROFILE\.local\bin",
        "$env:APPDATA\PowerShell\Scripts"
    )
    foreach ($dir in $candidates) {
        if (Test-Path $dir) { return $dir }
    }
    # None found: create the first candidate
    New-Item -ItemType Directory -Path $candidates[0] -Force | Out-Null
    return $candidates[0]
}

# --- AUTO-INSTALLAZIONE --------------------------------------------------------
function Invoke-Install {
    Write-Header "=== Installing claudebox ==="

    $installDir  = Get-InstallDir
    $destScript  = Join-Path $installDir 'claudebox.ps1'

    # FIX: $MyInvocation.PSCommandPath dentro una funzione si riferisce al chiamante
    # della funzione, non allo script. Usiamo $PSCommandPath (variabile automatica
    # a livello script) con fallback a $MyInvocation.MyCommand.Path e Definition.
    $sourceScript = $PSCommandPath
    if ([string]::IsNullOrWhiteSpace($sourceScript) -and $MyInvocation.MyCommand) {
        $sourceScript = $MyInvocation.MyCommand.Path
    }
    if ([string]::IsNullOrWhiteSpace($sourceScript) -and $MyInvocation.MyCommand) {
        $sourceScript = $MyInvocation.MyCommand.Definition
    }
    if ([string]::IsNullOrWhiteSpace($sourceScript) -or -not (Test-Path -LiteralPath $sourceScript)) {
        Write-Err "Cannot determine path of current script. Run it via '.\claudebox.ps1' (not piped through iex)."
    }

    # Se siamo già installati nella destinazione, evitiamo la copia su se stessi
    if ((Resolve-Path -LiteralPath $sourceScript).Path -eq $destScript) {
        Write-Ok "Script already at destination: $destScript"
    } else {
        # 1. Copy script
        Write-Info "Copying script to: $destScript"
        Copy-Item -LiteralPath $sourceScript -Destination $destScript -Force
        Write-Ok "Script copied"
    }

    # 2. Add directory to user PATH (if not already there)
    $currentPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
    if ($currentPath -notlike "*$installDir*") {
        [Environment]::SetEnvironmentVariable(
            'PATH', "$currentPath;$installDir", 'User')
        $env:PATH = "$env:PATH;$installDir"
        Write-Ok "Added to user PATH: $installDir"
    } else {
        Write-Info "$installDir already in PATH"
    }

    # 3. Add alias to PowerShell profile
    #
    # BUG STORICO: questo script ha un parametro `-Profile` che -- essendo PowerShell
    # case-insensitive sui nomi di variabili -- oscura la variabile automatica
    # `$PROFILE` (il path del profilo di PowerShell). Nel codice originale
    # `$PROFILE -is [string] -and $PROFILE -ne ''` era sempre vero con valore
    # 'personal' (il default del parametro), quindi $profilePath diventava 'personal'
    # e `Split-Path 'personal'` restituiva stringa vuota -> Test-Path '' -> errore:
    # "Impossibile associare l'argomento al parametro 'Path' perché è una stringa vuota".
    #
    # FIX: leggiamo esplicitamente la variabile automatica dallo scope globale e
    # aggiungiamo fallback difensivi per ogni possibile valore vuoto.
    $psProfile = Get-Variable -Name 'PROFILE' -Scope Global -ValueOnly -ErrorAction SilentlyContinue

    $profilePath = ''
    if ($psProfile) {
        # $PROFILE e' una stringa "arricchita" con proprieta' (CurrentUserAllHosts, ecc.).
        # Il cast a stringa restituisce il path CurrentUserCurrentHost, che e' quello che vogliamo.
        $profilePath = "$psProfile"
    }
    if ([string]::IsNullOrWhiteSpace($profilePath)) {
        # Fallback: costruiamo un path standard
        $docs = [Environment]::GetFolderPath('MyDocuments')
        if ([string]::IsNullOrWhiteSpace($docs)) { $docs = Join-Path $env:USERPROFILE 'Documents' }
        $psDirName = if ($PSVersionTable.PSVersion.Major -ge 6) { 'PowerShell' } else { 'WindowsPowerShell' }
        $profilePath = Join-Path $docs (Join-Path $psDirName 'Microsoft.PowerShell_profile.ps1')
    }

    $profileDir = Split-Path -Path $profilePath -Parent
    if ([string]::IsNullOrWhiteSpace($profileDir)) {
        # Ultimo baluardo: se Split-Path fallisce, andiamo in Documents
        $profileDir = Join-Path $env:USERPROFILE 'Documents'
    }
    if (-not (Test-Path -LiteralPath $profileDir)) {
        New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
    }
    if (-not (Test-Path -LiteralPath $profilePath)) {
        New-Item -ItemType File -Path $profilePath -Force | Out-Null
    }

    $aliasLine = "function claudebox { & '$destScript' @args }"
    $profileContent = Get-Content -LiteralPath $profilePath -Raw -ErrorAction SilentlyContinue
    if ($profileContent -notlike "*claudebox*") {
        Add-Content -LiteralPath $profilePath -Value "`n# claudebox alias (added by claudebox.ps1)`n$aliasLine"
        Write-Ok "Alias 'claudebox' added to profile: $profilePath"
    } else {
        Write-Info "Alias 'claudebox' already present in profile"
    }

    # 4. Load alias in current session
    Invoke-Expression $aliasLine

    Write-Host ""
    Write-Ok "Installation complete!"
    Write-Host ""
    # Usiamo $global:PROFILE per evitare che il template mostri il valore del parametro -Profile
    Write-Host "  Restart PowerShell (or run: . `$global:PROFILE) to use" -ForegroundColor White
    Write-Host "  the 'claudebox' command from any folder." -ForegroundColor White
    Write-Host ""
    Write-Host "  Quick start:" -ForegroundColor White
    Write-Host "    cd C:\your\projects\my-project" -ForegroundColor DarkGray
    Write-Host "    claudebox init" -ForegroundColor DarkGray
    Write-Host "    claudebox up" -ForegroundColor DarkGray
    Write-Host ""
}

# --- PREREQUISITI --------------------------------------------------------------
function Test-Prerequisites {
    Write-Header "=== Checking prerequisites ==="

    # Docker CLI
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Write-Err "Docker not found. Install it from https://www.docker.com/products/docker-desktop"
    }
    Write-Ok "Docker found: $(docker --version)"

    # Docker daemon
    $null = docker version 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Err "Docker daemon is not responding. Start Docker Desktop and try again."
    }
    Write-Ok "Docker daemon is running"

    # CLAUDE_CONFIG_DIR -- resolved from -Profile parameter
    $profileDir = Resolve-Profile $Profile
    if ($env:CLAUDE_CONFIG_DIR -and $Profile -eq 'personal') {
        $profileDir = $env:CLAUDE_CONFIG_DIR
    }
    $env:CLAUDE_CONFIG_DIR = $profileDir
    if (-not (Test-Path $env:CLAUDE_CONFIG_DIR)) {
        Write-Warn "Profile directory does not exist. Creating: $env:CLAUDE_CONFIG_DIR"
        New-Item -ItemType Directory -Path $env:CLAUDE_CONFIG_DIR -Force | Out-Null
    }
    Write-Ok "Profile '$Profile' -> $env:CLAUDE_CONFIG_DIR"

    # CLAUDE_PLUGINS_DIR (derived from CLAUDE_CONFIG_DIR)
    if (-not $env:CLAUDE_PLUGINS_DIR) {
        $env:CLAUDE_PLUGINS_DIR = "$env:CLAUDE_CONFIG_DIR\plugins"
    }
    Write-Ok "CLAUDE_PLUGINS_DIR -> $env:CLAUDE_PLUGINS_DIR"

    # CCSTATUSLINE_CONFIG_DIR
    if (-not $env:CCSTATUSLINE_CONFIG_DIR) {
        $ccDefault = "$env:USERPROFILE\.config\ccstatusline"
        if (Test-Path $ccDefault) {
            $env:CCSTATUSLINE_CONFIG_DIR = $ccDefault
            Write-Warn "CCSTATUSLINE_CONFIG_DIR not set; using: $ccDefault"
        } else {
            Write-Warn "CCSTATUSLINE_CONFIG_DIR not set and $ccDefault not found. ccstatusline will not be configured."
            $env:CCSTATUSLINE_CONFIG_DIR = $ccDefault
        }
    }
    Write-Ok "CCSTATUSLINE_CONFIG_DIR -> $env:CCSTATUSLINE_CONFIG_DIR"
}

# --- INIT ----------------------------------------------------------------------
# Base URL for official Anthropic files on GitHub (raw)
$ANTHROPIC_RAW_BASE = 'https://raw.githubusercontent.com/anthropics/claude-code/main/.devcontainer'

function Invoke-Download {
    param(
        [string]$Url,
        [string]$Dest,
        [string]$Label
    )
    Write-Info "Download $Label..."
    try {
        # Download as bytes to preserve original line endings (LF on Linux)
        $bytes = (Invoke-WebRequest -Uri $Url -UseBasicParsing -ErrorAction Stop).Content
        # Content may be string or byte[] depending on PS version
        if ($bytes -is [string]) {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($bytes)
        }
        [System.IO.File]::WriteAllBytes($Dest, $bytes)
        Write-Ok "$Label downloaded from official GitHub"
    } catch {
        Write-Err "Failed to download $Label from:`n  $Url`nError: $_`nCheck your internet connection and try again."
    }
}

# --- Dockerfile patches: discovery + execution -------------------------------
# Cerca file che matchano 'patch-dockerfile*.ps1' in DUE posizioni:
#   1. .devcontainer\    -> eseguiti con cwd=.devcontainer\
#                           (convenzione: patch usa $DOCKERFILE = 'Dockerfile')
#   2. project root      -> eseguiti con cwd=project root
#                           (convenzione: patch usa $DOCKERFILE = '.devcontainer\Dockerfile')
# Il glob 'patch-dockerfile*.ps1' cattura sia 'patch-dockerfile.ps1' che
# 'patch-dockerfile-java.ps1', etc. I patch DEVONO essere idempotenti.
function Invoke-DockerfilePatches {
    param([Parameter(Mandatory)][string]$ProjectRoot)

    $dcDir = Join-Path $ProjectRoot '.devcontainer'
    $script:dfpFound = $false

    function _Run-PatchIn {
        param([string]$Dir, [string]$PFile)
        if (-not (Test-Path -LiteralPath $PFile -PathType Leaf)) { return }
        if (-not $script:dfpFound) {
            Write-Header "=== Applying Dockerfile patches ==="
            $script:dfpFound = $true
        }
        $name = Split-Path -Leaf $PFile
        $rel  = $PFile.Substring($ProjectRoot.Length).TrimStart('\', '/')
        Write-Info "Running: $rel"
        Push-Location $Dir
        try {
            & $PFile patch
            if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
                Write-Warn "$name ha restituito exit code $LASTEXITCODE"
            } else {
                Write-Ok "$name applicato"
            }
        } catch {
            Write-Warn "$name ha lanciato un'eccezione: $_"
        } finally {
            Pop-Location
        }
    }

    # 1. Patches in .devcontainer\
    if (Test-Path -LiteralPath $dcDir) {
        Get-ChildItem -Path $dcDir -Filter 'patch-dockerfile*.ps1' -File `
            -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object {
            _Run-PatchIn -Dir $dcDir -PFile $_.FullName
        }
    }

    # 2. Patches in project root
    Get-ChildItem -Path $ProjectRoot -Filter 'patch-dockerfile*.ps1' -File `
        -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object {
        _Run-PatchIn -Dir $ProjectRoot -PFile $_.FullName
    }

    if ($script:dfpFound) { Write-Host "" }
}

function Invoke-Init {
    $proj  = Get-ProjectName
    $dcDir = Join-Path (Get-Location) ".devcontainer"

    Write-Header "=== Initializing devcontainer for '$proj' ==="

    if (Test-Path $dcDir) {
        Write-Warn "Folder $dcDir already exists."
        if (-not (Confirm-Step "Overwrite existing files? [y/N]")) { Write-Info "Cancelled."; return }
    }
    New-Item -ItemType Directory -Path $dcDir -Force | Out-Null

    # -- Dockerfile and init-firewall.sh: downloaded directly from Anthropic ----
    Write-Info "Downloading official files from anthropics/claude-code..."
    Invoke-Download `
        -Url  "$ANTHROPIC_RAW_BASE/Dockerfile" `
        -Dest "$dcDir\Dockerfile" `
        -Label "Dockerfile"

    Invoke-Download `
        -Url  "$ANTHROPIC_RAW_BASE/init-firewall.sh" `
        -Dest "$dcDir\init-firewall.sh" `
        -Label "init-firewall.sh"

    # -- devcontainer.json: generated with our customizations ------------------
    # Differences from the original Anthropic devcontainer:
    #   - "name" set to the current project folder name
    #   - Host CLAUDE_CONFIG_DIR -> /host-claude (read-only, never modified)
    #   - Shared Docker volume "claudebox-shared-config" -> /home/node/.claude
    #     (native Linux filesystem: no rename/atomic op issues on NTFS)
    #     On first start, credentials are copied automatically from /host-claude
    #   - Per-project history volume to avoid conflicts between projects
    Write-Info "Generating custom devcontainer.json..."
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
    "source=`${localEnv:CLAUDE_PLUGINS_DIR},target=/host-claude-plugins,type=bind,readonly=true,consistency=cached",
    "source=`${localEnv:CCSTATUSLINE_CONFIG_DIR},target=/host-ccstatusline,type=bind,readonly=true,consistency=cached",
    "source=claudebox-shared-config,target=/home/node/.claude,type=volume",
    "source=claudebox-shared-ccstatusline,target=/home/node/.config/ccstatusline,type=volume",
    "source=claudebox-$proj-history,target=/commandhistory,type=volume"
  ],
  "remoteUser": "node",
  "containerEnv": {
    "CLAUDE_CONFIG_DIR": "/home/node/.claude",
    "CLAUDE_PLUGINS_DIR": "/home/node/.claude/plugins",
    "CCSTATUSLINE_CONFIG_DIR": "/home/node/.config/ccstatusline",
    "NODE_OPTIONS": "--max-old-space-size=4096",
    "DEVCONTAINER": "true",
    "PATH": "/home/node/.local/bin:/usr/local/share/npm-global/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  },
  "runArgs": [
    "--cap-add=NET_ADMIN",
    "--cap-add=NET_RAW"
  ],
  "postStartCommand": "sudo chown -R node:node /home/node/.claude /home/node/.config && mkdir -p /home/node/.local/bin /home/node/.config/ccstatusline /home/node/.claude/plugins && if [ ! -f /home/node/.claude/.credentials.json ]; then cp -rn /host-claude/. /home/node/.claude/ 2>/dev/null || true; fi && cp -rn /host-claude-plugins/. /home/node/.claude/plugins/ 2>/dev/null || true && if [ ! -f /home/node/.config/ccstatusline/settings.json ]; then cp -rn /host-ccstatusline/. /home/node/.config/ccstatusline/ 2>/dev/null || true; fi && sudo /usr/local/bin/init-firewall.sh 2>/dev/null || true",
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
    # Write with LF line endings (cross-platform)
    $jsonLf    = $devcontainerJson -replace "`r`n", "`n"
    $jsonBytes = [System.Text.Encoding]::UTF8.GetBytes($jsonLf)
    $jsonPath  = Join-Path $dcDir "devcontainer.json"
    [System.IO.File]::WriteAllBytes($jsonPath, $jsonBytes)

    Write-Ok "Generated $dcDir\devcontainer.json (customized)"
    Write-Host ""
    Write-Host "  Files in .devcontainer folder:" -ForegroundColor DarkGray
    Write-Host "    Dockerfile        <- official anthropics/claude-code" -ForegroundColor DarkGray
    Write-Host "    init-firewall.sh  <- official anthropics/claude-code" -ForegroundColor DarkGray
    Write-Host "    devcontainer.json <- customized (project name + config mounts)" -ForegroundColor DarkGray

    # Apply project-specific Dockerfile patches (idempotent, see README)
    Invoke-DockerfilePatches -ProjectRoot (Get-Location).Path

    Write-Host ""
    Write-Info "Next step: claudebox up"
}

# --- UP ------------------------------------------------------------------------
function Invoke-Up {
    Test-Prerequisites

    if (-not (Test-Path ".devcontainer\devcontainer.json")) {
        Write-Err "No .devcontainer found. Run first: claudebox init"
    }

    $proj  = Get-ProjectName
    $cname = Get-ContainerName
    # NOTA: evitiamo di sovrascrivere $PWD (variabile automatica di PowerShell)
    $currentDir = (Get-Location).Path

    # Normalize path for Docker (convert backslash -> slash and C: -> /c)
    # Convert C:\foo\bar -> /c/foo/bar (scriptblock in -replace does not work in PS 5.x)
    function Convert-ToDockerPath([string]$winPath) {
        $p = $winPath -replace '\\', '/'
        if ($p -match '^([A-Za-z]):(.*)') {
            return '/' + $Matches[1].ToLower() + $Matches[2]
        }
        return $p
    }
    $dockerWorkspace        = Convert-ToDockerPath $currentDir
    $dockerConfigDir        = Convert-ToDockerPath $env:CLAUDE_CONFIG_DIR
    $dockerPluginsDir       = Convert-ToDockerPath $env:CLAUDE_PLUGINS_DIR
    $dockerCcstatuslineDir  = Convert-ToDockerPath $env:CCSTATUSLINE_CONFIG_DIR

    Write-Header "=== Starting devcontainer '$proj' ==="

    # Safety net: ri-applica patch project-specific (caso: aggiunti dopo init,
    # oppure update upstream ha sovrascritto il Dockerfile da un'altra sessione).
    # I patch sono idempotenti, quindi se gia' applicati e' un no-op.
    Invoke-DockerfilePatches -ProjectRoot $currentDir

    # -- Pin versione Claude Code nel Dockerfile (prima della build) ------------
    # Forza l'invalidazione della cache Docker solo quando c'e' effettivamente
    # una versione nuova. Se la versione e' la stessa, il file non cambia e
    # la cache viene riutilizzata.
    if (-not $NoUpdate) {
        Write-Info "Checking latest Claude Code version on npm..."
        $latestVer = Get-LatestClaudeCodeVersion
        if ($latestVer) {
            $dfPath = Join-Path $currentDir '.devcontainer\Dockerfile'
            $changed = Update-DockerfileClaudeVersion -DockerfilePath $dfPath -Version $latestVer
            if ($changed) {
                Write-Ok "Dockerfile pinned to claude-code@$latestVer (image layer will rebuild)"
            } else {
                Write-Ok "Claude Code already pinned to $latestVer (Docker cache will be reused)"
            }
        } else {
            Write-Warn "Could not reach npm registry. Building with Dockerfile as-is."
        }
    } else {
        Write-Info "Skipping version pin (-NoUpdate). Building with Dockerfile as-is."
    }

    # -- Build ------------------------------------------------------------------
    Write-Info "Building Docker image (may take a few minutes on first run)..."
    docker build -t "claudebox-img-$proj" .devcontainer
    Write-Ok "Image ready: claudebox-img-$proj"

    # -- Verifica accesso Docker alla CLAUDE_CONFIG_DIR -------------------------
    Write-Info "Verifying Docker can access CLAUDE_CONFIG_DIR..."
    $probeOutput = & docker run --rm `
        -v "${dockerConfigDir}:/probe:ro" `
        "claudebox-img-$proj" `
        ls /probe 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host ""
        Write-Host "  ERR Docker cannot access the folder:" -ForegroundColor Red
        Write-Host "      $env:CLAUDE_CONFIG_DIR" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  You need to add it to Docker Desktop File Sharing:" -ForegroundColor White
        Write-Host ""
        Write-Host "    1. Open Docker Desktop" -ForegroundColor DarkGray
        Write-Host "    2. Go to Settings -> Resources -> File Sharing" -ForegroundColor DarkGray
        Write-Host "    3. Add this path:" -ForegroundColor DarkGray
        Write-Host "       $env:CLAUDE_CONFIG_DIR" -ForegroundColor Cyan
        Write-Host "    4. Click Apply & Restart" -ForegroundColor DarkGray
        Write-Host "    5. Run again: claudebox up" -ForegroundColor DarkGray
        Write-Host ""
        exit 1
    }
    Write-Ok "Docker can access CLAUDE_CONFIG_DIR"

    # Probe ccstatusline dir (optional - does not block if missing)
    if ($env:CCSTATUSLINE_CONFIG_DIR -and (Test-Path $env:CCSTATUSLINE_CONFIG_DIR)) {
        $probeCs = & docker run --rm `
            -v "${dockerCcstatuslineDir}:/probe-cs:ro" `
            "claudebox-img-$proj" `
            ls /probe-cs 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Warn "Docker cannot access CCSTATUSLINE_CONFIG_DIR ($env:CCSTATUSLINE_CONFIG_DIR)."
            Write-Host "  Add it in Docker Desktop -> Settings -> Resources -> File Sharing" -ForegroundColor DarkGray
            Write-Host "  ccstatusline will proceed without custom config." -ForegroundColor DarkGray
        } else {
            Write-Ok "Docker can access CCSTATUSLINE_CONFIG_DIR"
        }
    }

    # -- Detect if this is a new profile (volume does not exist yet) ------------
    $volSuffix    = Get-VolumeSuffix $Profile
    $configVol    = "claudebox-shared-config-$volSuffix"
    $personalVol  = 'claudebox-shared-config-personal'
    $isNewProfile = $false
    if ($Profile -ne 'personal') {
        $existingVols = docker volume ls --format '{{.Name}}' 2>$null
        if ($existingVols -notcontains $configVol) {
            $isNewProfile = $true
            Write-Info "New profile '$Profile' -- seeding from personal config..."
            # Create the new volume by copying from personal
            docker run --rm `
                -v "${personalVol}:/src:ro" `
                -v "${configVol}:/dst" `
                alpine sh -c 'cp -a /src/. /dst/' | Out-Null
            Write-Ok "Volume '$configVol' seeded from '$personalVol'"
        }
    }

    # -- Rimuovi container precedente -------------------------------------------
    if (Test-ContainerExists) {
        Write-Info "Removing previous container '$cname'..."
        docker rm -f $cname | Out-Null
    }

    # -- Docker-outside-of-Docker (DooD) support --------------------------------
    # Se il Dockerfile contiene il marker del patch docker, montiamo il socket
    # dell'host dentro al container.
    # Su Windows con Docker Desktop, /var/run/docker.sock e' un proxy esposto
    # automaticamente: il bind mount funziona anche se il path "Unix" non
    # esiste lato host. GID alignment non serve (Docker Desktop espone il
    # socket world-rw nella VM WSL2/HyperKit), quindi niente --group-add.
    $dockerExtraOpts = @()
    $dockerfilePath = '.devcontainer\Dockerfile'
    if (Test-Path -LiteralPath $dockerfilePath) {
        $dockerfileContent = Get-Content -LiteralPath $dockerfilePath -Raw
        if ($dockerfileContent -match 'CLAUDEBOX_PATCH_DOCKER_BEGIN') {
            $dockerExtraOpts += @('-v', '/var/run/docker.sock:/var/run/docker.sock')
            Write-Info "Docker patch detected: mounting host docker.sock (DooD)"
        }
    }

    # -- Avvia container --------------------------------------------------------
    Write-Info "Starting container '$cname'..."
    docker run -d `
        --name $cname `
        --cap-add=NET_ADMIN `
        --cap-add=NET_RAW `
        @dockerExtraOpts `
        -v "${dockerWorkspace}:/workspace:cached" `
        -v "${dockerConfigDir}:/host-claude:ro" `
        -v "${dockerPluginsDir}:/host-claude-plugins:ro" `
        -v "${dockerCcstatuslineDir}:/host-ccstatusline:ro" `
        -v "claudebox-shared-config-$(Get-VolumeSuffix $Profile):/home/node/.claude" `
        -v "claudebox-shared-ccstatusline-$(Get-VolumeSuffix $Profile):/home/node/.config/ccstatusline" `
        -v "claudebox-${proj}-history:/commandhistory" `
        -e CLAUDE_CONFIG_DIR="/home/node/.claude" `
        -e CLAUDE_PLUGINS_DIR="/home/node/.claude/plugins" `
        -e CCSTATUSLINE_CONFIG_DIR="/home/node/.config/ccstatusline" `
        -w /workspace `
        "claudebox-img-$proj" `
        sleep infinity | Out-Null
    Write-Ok "Container started"

    # -- Firewall ---------------------------------------------------------------
    Write-Info "Initializing firewall..."
    try {
        # Copy config from host to shared volume on first start
        docker exec $cname bash -c 'if [ ! -f /home/node/.claude/.credentials.json ]; then cp -rn /host-claude/. /home/node/.claude/ 2>/dev/null || true; fi' | Out-Null
        # Copy plugins from host on every start (plugins may be updated)
        docker exec -u root $cname chown -R node:node /home/node/.claude/plugins | Out-Null
        docker exec $cname bash -c 'cp -rn /host-claude-plugins/. /home/node/.claude/plugins/ 2>/dev/null || true' | Out-Null
        # Copy ccstatusline config on first start
        docker exec -u root $cname chown -R node:node /home/node/.config/ccstatusline | Out-Null
        docker exec $cname bash -c 'mkdir -p /home/node/.config/ccstatusline && if [ ! -f /home/node/.config/ccstatusline/settings.json ]; then cp -rn /host-ccstatusline/. /home/node/.config/ccstatusline/ 2>/dev/null || true; fi' | Out-Null
        # Fix host paths -> container paths in Claude Code JSON config files
        # Written to a temp file and copied via docker cp to avoid all quote-stripping issues
        $fixJs = @'
var fs = require('fs'), path = require('path');
var DIR = '/home/node/.claude';

// 1. Structured fix for known_marketplaces.json
var km = path.join(DIR, 'plugins/known_marketplaces.json');
if (fs.existsSync(km)) {
  try {
    var d = JSON.parse(fs.readFileSync(km, 'utf8'));
    for (var k in d) {
      if (d[k].installLocation)
        d[k].installLocation = DIR + '/plugins/marketplaces/' + k;
    }
    fs.writeFileSync(km, JSON.stringify(d, null, 2), 'utf8');
  } catch(e) {}
}

// 2. Structured fix for installed_plugins.json installPath fields
var ip = path.join(DIR, 'plugins/installed_plugins.json');
if (fs.existsSync(ip)) {
  try {
    var data = JSON.parse(fs.readFileSync(ip, 'utf8'));
    var changed = false;
    for (var k in data.plugins) {
      (data.plugins[k] || []).forEach(function(e) {
        if (e.installPath) {
          var p = e.installPath.replace(/\\\\/g, '/').replace(/\\/g, '/').replace(/\/+/g, '/');
          var fixed = p.replace(/^(?:[A-Za-z]:\/|\/(?:Users|home)\/[^\/]+\/).*?\.claude/, DIR);
          if (fixed !== e.installPath) { e.installPath = fixed; changed = true; }
        }
      });
    }
    if (changed) fs.writeFileSync(ip, JSON.stringify(data, null, 2), 'utf8');
  } catch(e) {}
}

// 3. Generic regex scan on plugins/, ide/, config/
// Matches Windows (C:\\ or C:/) and Unix (/Users/ or /home/) paths
var DIRS = ['plugins', 'ide', 'config'];
var RE = /(?:[A-Za-z]:[\\\/]|\/(?:Users|home)\/)(?:[^'"\n])+/g;
function fixPath(m) {
  var p = m.replace(/\\\\/g, '/').replace(/\\/g, '/').replace(/\/+/g, '/');
  return p.replace(/^(?:[A-Za-z]:\/|\/(?:Users|home)\/[^\/]+\/).*?\.claude/, DIR);
}
function fixFile(f) {
  try {
    var r = fs.readFileSync(f, 'utf8');
    RE.lastIndex = 0;
    if (!RE.test(r)) return;
    RE.lastIndex = 0;
    var x = r.replace(RE, fixPath);
    if (x !== r) fs.writeFileSync(f, x, 'utf8');
  } catch(e) {}
}
function walk(d) {
  var e; try { e = fs.readdirSync(d, {withFileTypes:true}); } catch(x) { return; }
  for (var i = 0; i < e.length; i++) {
    var p = path.join(d, e[i].name);
    if (e[i].isDirectory()) walk(p);
    else if (e[i].name.slice(-5) === '.json') fixFile(p);
  }
}
for (var i = 0; i < DIRS.length; i++) walk(path.join(DIR, DIRS[i]));
'@
        $tmpJs = Join-Path $env:TEMP 'claudebox-fix-paths.js'
        [System.IO.File]::WriteAllText($tmpJs, $fixJs)
        docker cp $tmpJs "${cname}:/tmp/claudebox-fix-paths.js" | Out-Null
        docker exec -u node $cname node /tmp/claudebox-fix-paths.js 2>$null | Out-Null
        Remove-Item $tmpJs -ErrorAction SilentlyContinue
        docker exec $cname sudo /usr/local/bin/init-firewall.sh 2>&1 | Out-Null
        Write-Ok "Firewall applied"
    } catch {
        Write-Warn "Firewall not applied (NET_ADMIN may not be available)."
    }

    # -- Verifica isolamento ----------------------------------------------------
    Write-Header "=== Container isolation check ==="
    $workdir = docker exec -u node $cname pwd
    if ($workdir.Trim() -eq '/workspace') {
        Write-Ok "Isolation confirmed: pwd = /workspace"
    } else {
        Write-Err "Isolation NOT verified: pwd = '$workdir' (expected /workspace)"
    }

    # -- Lancio Claude Code interattivo -----------------------------------------
    if ($isNewProfile) {
        Write-Header "=== First login for profile '$Profile' ==="
        Write-Host "  Please log in with your account for this profile." -ForegroundColor Yellow
        Write-Host "  After login, Claude Code will start automatically.`n" -ForegroundColor Yellow
        docker exec -it -u node $cname zsh -c 'claude login && claude --dangerously-skip-permissions; exec zsh'
    } else {
        Write-Header "=== Launching Claude Code (--dangerously-skip-permissions) ==="
        Write-Host "  Container is ready. Launching Claude Code..." -ForegroundColor Yellow
        Write-Host "  Type 'exit' to leave the container shell.`n" -ForegroundColor Yellow
        docker exec -it -u node $cname zsh -c 'claude --dangerously-skip-permissions; exec zsh'
    }
}

# --- UPDATE: ri-scarica Dockerfile e init-firewall.sh da Anthropic ------------
function Invoke-Update {
    $dcDir = Join-Path (Get-Location) ".devcontainer"

    Write-Header "=== Updating official Anthropic files ==="

    if (-not (Test-Path $dcDir)) {
        Write-Err "No .devcontainer found. Run first: claudebox init"
    }

    Write-Info "Downloading updated files from anthropics/claude-code (main)..."
    Invoke-Download `
        -Url  "$ANTHROPIC_RAW_BASE/Dockerfile" `
        -Dest "$dcDir\Dockerfile" `
        -Label "Dockerfile"

    Invoke-Download `
        -Url  "$ANTHROPIC_RAW_BASE/init-firewall.sh" `
        -Dest "$dcDir\init-firewall.sh" `
        -Label "init-firewall.sh"

    # Re-apply project-specific patches (the download just wiped them)
    Invoke-DockerfilePatches -ProjectRoot (Get-Location).Path

    Write-Host ""
    Write-Ok "Official files updated. devcontainer.json unchanged."
    Write-Info "Run 'claudebox up' to rebuild the image with the updates."
}

# --- START: init + up in un solo comando --------------------------------------
function Invoke-Start {
    $proj  = Get-ProjectName
    $dcDir = Join-Path (Get-Location) ".devcontainer"

    # -- Banner -----------------------------------------------------------------
    Write-Host ""
    Write-Host "  +======================================================+" -ForegroundColor Blue
    Write-Host "  |         claudebox  --  automated setup              |" -ForegroundColor Blue
    Write-Host "  +======================================================+" -ForegroundColor Blue
    Write-Host ""
    Write-Host "  Project  : " -NoNewline -ForegroundColor DarkGray
    Write-Host $proj -ForegroundColor White
    Write-Host "  Profile  : " -NoNewline -ForegroundColor DarkGray
    if ($Profile -eq "personal") { Write-Host $Profile -ForegroundColor White }
    else { Write-Host $Profile -ForegroundColor Cyan }
    Write-Host "  Folder   : " -NoNewline -ForegroundColor DarkGray
    Write-Host (Get-Location).Path -ForegroundColor White

    # -- Resolve CLAUDE_CONFIG_DIR before showing the summary ------------------
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

    # If still not found, ask interactively
    if (-not $env:CLAUDE_CONFIG_DIR -or -not (Test-Path $env:CLAUDE_CONFIG_DIR)) {
        Write-Host ""
        Write-Warn "CLAUDE_CONFIG_DIR not set or not found automatically."
        Write-Host ""
        Write-Host "  Claude Code stores credentials and settings in a dedicated folder." -ForegroundColor DarkGray
        Write-Host "  Usually located at: $env:USERPROFILE\.claude" -ForegroundColor DarkGray
        Write-Host ""
        $inputDir = Read-InputOrDefault "  Enter Claude config path (press Enter for default: $env:USERPROFILE\.claude)" "$env:USERPROFILE\.claude"
        # Create directory if missing (first Claude Code run)
        if (-not (Test-Path $inputDir)) {
            Write-Warn "Folder '$inputDir' does not exist. Creating it now (will be populated by Claude Code on first run)."
            New-Item -ItemType Directory -Path $inputDir -Force | Out-Null
        }
        $env:CLAUDE_CONFIG_DIR = $inputDir
        # Save permanently for future sessions
        [Environment]::SetEnvironmentVariable('CLAUDE_CONFIG_DIR', $inputDir, 'User')
        Write-Ok "CLAUDE_CONFIG_DIR set permanently: $inputDir"
    }

    Write-Host "  Config   : " -NoNewline -ForegroundColor DarkGray
    Write-Host $env:CLAUDE_CONFIG_DIR -ForegroundColor White
    Write-Host "  Plugins  : " -NoNewline -ForegroundColor DarkGray
    Write-Host "$env:CLAUDE_CONFIG_DIR\plugins" -ForegroundColor White
    Write-Host "  ccstatus : " -NoNewline -ForegroundColor DarkGray
    if ($env:CCSTATUSLINE_CONFIG_DIR -and (Test-Path $env:CCSTATUSLINE_CONFIG_DIR)) {
        Write-Host $env:CCSTATUSLINE_CONFIG_DIR -ForegroundColor White
    } else {
        Write-Host "(not found, will be skipped)" -ForegroundColor DarkGray
    }

    # -- Current state ----------------------------------------------------------
    $hasDevcontainer = Test-Path "$dcDir\devcontainer.json"
    $containerExists = Test-ContainerExists
    $containerRunning = Test-ContainerRunning

    # Decide whether to update here, so we can include it in the step summary
    $doUpdate = $false
    if ($hasDevcontainer) {
        Write-Host ""
        Write-Host "  +- Dockerfile and init-firewall.sh may be outdated." -ForegroundColor DarkGray
        Write-Host "  |  Update official Anthropic files before starting?" -ForegroundColor DarkGray
        if ($AutoYes) { $doUpdate = $false }
        else { $doUpdate = (Read-Host "  +- Update? [y/N]").ToLower() -eq 'y' }
    }

    Write-Host ""
    Write-Host "  Current state:" -ForegroundColor DarkGray
    Write-Host "    .devcontainer : " -NoNewline -ForegroundColor DarkGray
    if ($hasDevcontainer) {
        Write-Host "present" -ForegroundColor Green
    } else {
        Write-Host "missing  -> will be created" -ForegroundColor Yellow
    }
    Write-Host "    Container     : " -NoNewline -ForegroundColor DarkGray
    if ($containerRunning) {
        Write-Host "running  -> will be recreated" -ForegroundColor Yellow
    } elseif ($containerExists) {
        Write-Host "stopped  -> will be recreated" -ForegroundColor Yellow
    } else {
        Write-Host "missing  -> will be created" -ForegroundColor Yellow
    }

    # Dynamically number the steps
    $step = 1
    Write-Host ""
    Write-Host "  Steps to be executed:" -ForegroundColor DarkGray
    if (-not $hasDevcontainer) {
        Write-Host "    $step. init   -- download official Anthropic files and generate devcontainer.json" -ForegroundColor DarkGray
        $step++
    } elseif ($doUpdate) {
        Write-Host "    $step. update -- re-download Dockerfile and init-firewall.sh from Anthropic" -ForegroundColor DarkGray
        $step++
    }
    Write-Host "    $step. build  -- build the Docker image" -ForegroundColor DarkGray; $step++
    Write-Host "    $step. run    -- start container and mount directories" -ForegroundColor DarkGray; $step++
    Write-Host "    $step. check  -- verify isolation (pwd = /workspace)" -ForegroundColor DarkGray; $step++
    Write-Host "    $step. claude -- launch claude --dangerously-skip-permissions" -ForegroundColor DarkGray
    Write-Host ""

    if (-not (Confirm-Step "  Start? [Y/n]")) { Write-Info "Cancelled."; return }

    # -- Step: init o update ----------------------------------------------------
    if (-not $hasDevcontainer) {
        Write-Host ""
        Write-Header "=== Init devcontainer ==="
        Invoke-Init
    } elseif ($doUpdate) {
        Write-Host ""
        Write-Header "=== Update official Anthropic files ==="
        Invoke-Update
    } else {
        Write-Host ""
        Write-Ok "Using existing configuration in $dcDir\ (no update requested)"
    }

    # -- Up: build + run + verifica + claude ------------------------------------
    Write-Host ""
    Invoke-Up
}

# --- SHELL ---------------------------------------------------------------------
function Invoke-Shell {
    $cname = Get-ContainerName
    if (-not (Test-ContainerRunning)) {
        Write-Err "Container '$cname' is not running. Use: claudebox up"
    }
    Write-Info "Opening shell in '$cname'..."
    docker exec -it -u node $cname zsh
}

# --- STOP ----------------------------------------------------------------------
function Invoke-Stop {
    $cname = Get-ContainerName
    if (-not (Test-ContainerRunning)) { Write-Info "Container is not running."; return }
    docker stop $cname | Out-Null
    Write-Ok "Container '$cname' stopped."
}

# --- DESTROY -------------------------------------------------------------------
function Invoke-Destroy {
    $proj  = Get-ProjectName
    $cname = Get-ContainerName
    Write-Warn "This will remove the container, history volume and image for '$proj'."
    Write-Host "  Shared volumes for profile '$Profile' are NOT removed." -ForegroundColor DarkGray
    Write-Host "  To remove: docker volume rm claudebox-shared-config-$(Get-VolumeSuffix $Profile) claudebox-shared-ccstatusline-$(Get-VolumeSuffix $Profile)" -ForegroundColor DarkGray
    if (-not (Confirm-Step "Continue? [y/N]")) { Write-Info "Cancelled."; return }

    if (Test-ContainerExists) {
        docker rm -f $cname | Out-Null
        Write-Ok "Container removed"
    }
    docker volume rm "claudebox-${proj}-history" 2>$null | Out-Null
    Write-Ok "History volume removed (if it existed)"
    docker rmi "claudebox-img-$proj" 2>$null | Out-Null
    Write-Ok "Image removed (if it existed)"

    Write-Host ""
    Write-Host "  To also remove the shared config volume (Claude credentials and settings):" -ForegroundColor DarkGray
    Write-Host "    docker volume rm claudebox-shared-config" -ForegroundColor DarkGray
}

# --- HELP ----------------------------------------------------------------------
function Show-Help {
    Write-Host @"

  claudebox -- isolated Claude Code devcontainer for the current project folder

  USAGE
    claudebox <command>

  COMMANDS
    install   Self-install: copy script to PATH and add alias to PS profile
    start     Full auto-setup: init (if needed) + build + run + claude
    init      Download Dockerfile and init-firewall.sh from Anthropic, generate devcontainer.json
    update    Re-download Dockerfile and init-firewall.sh from Anthropic (devcontainer.json unchanged)
    up        Build image, start container, verify isolation, launch claude
    shell     Open a shell in the running container
    stop      Stop the container (without removing it)
    destroy   Remove container, history volume and image

  ENVIRONMENT VARIABLES
    CLAUDE_CONFIG_DIR   Claude Code config directory
                        (default: ~\.claude if it exists)

  FIRST RUN
    # Download and install (one-time):
    .\claudebox.ps1

    # Then from any project folder -- all in one command:
    cd C:\projects\my-project
    claudebox start
    claudebox start -y              # skip all confirmations
    claudebox start -Profile work   # use work profile (~/.claude-work)
    claudebox start -p work -y      # work profile, no prompts
    claudebox start -NoUpdate       # keep Claude Code version from image (no npm update)

    # Or step by step:
    claudebox init
    claudebox up

"@ -ForegroundColor White
}

# --- ENTRY POINT ---------------------------------------------------------------
# If run without arguments, self-install
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
