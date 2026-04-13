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
    [switch]$AutoYes
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
    $sourceScript = $MyInvocation.PSCommandPath

    # 1. Copy script
    Write-Info "Copying script to: $destScript"
    Copy-Item -Path $sourceScript -Destination $destScript -Force
    Write-Ok "Script copied"

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
        Add-Content -Path $profilePath -Value "`n# claudebox alias (added by claudebox.ps1)`n$aliasLine"
        Write-Ok "Alias 'claudebox' added to profile: $profilePath"
    } else {
        Write-Info "Alias 'claudebox' already present in profile"
    }

    # 4. Load alias in current session
    Invoke-Expression $aliasLine

    Write-Host ""
    Write-Ok "Installation complete!"
    Write-Host ""
    Write-Host "  Restart PowerShell (or run: . `$PROFILE) to use" -ForegroundColor White
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
    try {
        docker info 2>&1 | Out-Null
        Write-Ok "Docker daemon is running"
    } catch {
        Write-Err "Docker daemon is not responding. Start Docker Desktop and try again."
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
                Write-Warn "CLAUDE_CONFIG_DIR not set; using: $c"
                break
            }
        }
        if (-not $env:CLAUDE_CONFIG_DIR) {
            Write-Err (@"
CLAUDE_CONFIG_DIR is not set and no Claude folder was found.
Set the variable before using this command:
  `$env:CLAUDE_CONFIG_DIR = "`$env:USERPROFILE\.claude"
Or permanently:
  [Environment]::SetEnvironmentVariable('CLAUDE_CONFIG_DIR', "`$env:USERPROFILE\.claude", 'User')
"@)
        }
    }

    if (-not (Test-Path $env:CLAUDE_CONFIG_DIR)) {
        Write-Err "CLAUDE_CONFIG_DIR='$env:CLAUDE_CONFIG_DIR' does not exist."
    }
    Write-Ok "CLAUDE_CONFIG_DIR -> $env:CLAUDE_CONFIG_DIR"

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
    $pwd   = (Get-Location).Path

    # Normalize path for Docker (convert backslash -> slash and C: -> /c)
    # Convert C:\foo\bar -> /c/foo/bar (scriptblock in -replace does not work in PS 5.x)
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

    Write-Header "=== Starting devcontainer '$proj' ==="

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

    # -- Rimuovi container precedente -------------------------------------------
    if (Test-ContainerExists) {
        Write-Info "Removing previous container '$cname'..."
        docker rm -f $cname | Out-Null
    }

    # -- Avvia container --------------------------------------------------------
    Write-Info "Starting container '$cname'..."
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
    Write-Ok "Container started"

    # -- Firewall ---------------------------------------------------------------
    Write-Info "Initializing firewall..."
    try {
        # Copy config from host to shared volume on first start
        docker exec $cname bash -c 'if [ ! -f /home/node/.claude/.credentials.json ]; then cp -rn /host-claude/. /home/node/.claude/ 2>/dev/null || true; fi' | Out-Null
        # Copy ccstatusline config on first start
        docker exec -u root $cname chown -R node:node /home/node/.config/ccstatusline | Out-Null
        docker exec $cname bash -c 'mkdir -p /home/node/.config/ccstatusline && if [ ! -f /home/node/.config/ccstatusline/settings.json ]; then cp -rn /host-ccstatusline/. /home/node/.config/ccstatusline/ 2>/dev/null || true; fi' | Out-Null
        # Fix Windows -> Linux paths in Claude Code JSON config files
        # All JS strings use single-quotes: docker exec on Windows strips double-quotes
        docker exec -u node $cname node -e @'
var fs = require('fs'), path = require('path');
var DIR = '/home/node/.claude';
var DIRS = ['plugins', 'ide', 'config'];
var RE = /[A-Za-z]:[\\\/][^'\n]*/g;
function fixFile(f) {
  try {
    var r = fs.readFileSync(f, 'utf8');
    RE.lastIndex = 0;
    if (!RE.test(r)) return;
    RE.lastIndex = 0;
    var x = r.replace(RE, function(m) {
      return m.replace(/\\/g, '/').replace(/^[A-Za-z]:\/.*?\.claude/, DIR);
    });
    if (x !== r) fs.writeFileSync(f, x, 'utf8');
  } catch(e) {}
}
function walk(d) {
  var e; try { e = fs.readdirSync(d, {withFileTypes:true}); } catch(x){return;}
  for (var i=0;i<e.length;i++) {
    var p = path.join(d, e[i].name);
    if (e[i].isDirectory()) walk(p);
    else if (e[i].name.slice(-5) === '.json') fixFile(p);
  }
}
for (var i=0;i<DIRS.length;i++) walk(path.join(DIR, DIRS[i]));
'@ 2>$null | Out-Null
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
    Write-Header "=== Launching Claude Code (--dangerously-skip-permissions) ==="
    Write-Host "  Container is ready. Launching Claude Code..." -ForegroundColor Yellow
    Write-Host "  Type 'exit' to leave the container shell.`n" -ForegroundColor Yellow

    docker exec -it -u node $cname zsh -c 'claude --dangerously-skip-permissions; exec zsh'
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
    Write-Host "  Shared volume 'claudebox-shared-config' is NOT removed (shared across projects)." -ForegroundColor DarkGray
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
    claudebox start -y     # skip all confirmations

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
