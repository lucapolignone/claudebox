#Requires -Version 5.1
<#
.SYNOPSIS
    patch-dockerfile-java.ps1 -- aggiunge Java 21 + Maven al Dockerfile di claudebox

.DESCRIPTION
    Appende al Dockerfile ufficiale un layer con OpenJDK 21 (Eclipse Temurin) e
    Apache Maven. Idempotente: usa marker per rilevare se il patch e' gia' presente.

.PARAMETER Command
    Comando: patch | remove | status | help (default: patch)

.NOTES
    POSIZIONAMENTO CONSIGLIATO:
        .devcontainer\patch-dockerfile-java.ps1
    claudebox lo esegue AUTOMATICAMENTE dopo init/update e prima di up.
    Il patch non sparisce piu' quando claudebox ri-scarica il Dockerfile.

.EXAMPLE
    # Workflow automatico:
    Copy-Item patch-dockerfile-java.ps1 .devcontainer\
    claudebox start -y

.EXAMPLE
    # Workflow manuale:
    claudebox init
    .\patch-dockerfile-java.ps1 patch
    claudebox start -y -n
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
if (-not $env:MAVEN_VERSION) { $env:MAVEN_VERSION = '3.9.9' }
$MAVEN_VERSION = $env:MAVEN_VERSION
$MARKER_BEGIN  = '# >>> CLAUDEBOX_PATCH_JAVA_BEGIN >>>'
$MARKER_END    = '# <<< CLAUDEBOX_PATCH_JAVA_END <<<'

# ── Output helpers ─────────────────────────────────────────────────────────────
function Write-Info ($msg) { Write-Host "  $([char]0x25B8) $msg" -ForegroundColor Cyan   }
function Write-Ok   ($msg) { Write-Host "  $([char]0x2714) $msg" -ForegroundColor Green  }
function Write-Warn ($msg) { Write-Host "  $([char]0x26A0) $msg" -ForegroundColor Yellow }
function Write-Err  ($msg) { Write-Host "  $([char]0x2716) $msg" -ForegroundColor Red; exit 1 }

# ── Dockerfile discovery ───────────────────────────────────────────────────────
# Il patch script puo' essere eseguito da 3 contesti diversi:
#   a) da claudebox.ps1 (cwd=.devcontainer\)       -> .\Dockerfile
#   b) dall'utente in project root                  -> .\.devcontainer\Dockerfile
#   c) dall'utente in .devcontainer\                -> .\Dockerfile
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
        Write-Ok "Patch Java gia' presente in $DOCKERFILE. Niente da fare."
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
# Java 21 (Eclipse Temurin) + Maven $MAVEN_VERSION
# Aggiunto da patch-dockerfile-java.ps1 -- il patch e' idempotente e viene
# riapplicato automaticamente da claudebox se il file e' in .devcontainer\

USER root

# 1. Eclipse Temurin 21 JDK via repo Adoptium (cross-distro, cross-arch)
RUN apt-get update && apt-get install -y --no-install-recommends ``
        wget gnupg apt-transport-https ca-certificates ``
    && wget -qO - https://packages.adoptium.net/artifactory/api/gpg/key/public ``
        | gpg --dearmor -o /usr/share/keyrings/adoptium.gpg ``
    && chmod a+r /usr/share/keyrings/adoptium.gpg ``
    && . /etc/os-release ``
    && echo "deb [signed-by=/usr/share/keyrings/adoptium.gpg] https://packages.adoptium.net/artifactory/deb `${VERSION_CODENAME} main" ``
        > /etc/apt/sources.list.d/adoptium.list ``
    && apt-get update && apt-get install -y --no-install-recommends temurin-21-jdk ``
    && apt-get clean && rm -rf /var/lib/apt/lists/* ``
    && ln -sfn "`$(dirname `$(dirname `$(readlink -f /usr/bin/java)))" /usr/local/java-21

ENV JAVA_HOME=/usr/local/java-21
ENV PATH="`${JAVA_HOME}/bin:`${PATH}"

# 2. Maven $MAVEN_VERSION da Apache archive (conserva TUTTE le versioni; dlcdn tiene solo le ultime)
RUN curl -fsSL ``
    "https://archive.apache.org/dist/maven/maven-3/$MAVEN_VERSION/binaries/apache-maven-$MAVEN_VERSION-bin.tar.gz" ``
    | tar -xzC /opt ``
    && ln -s "/opt/apache-maven-$MAVEN_VERSION" /opt/maven ``
    && ln -sf /opt/maven/bin/mvn      /usr/local/bin/mvn ``
    && ln -sf /opt/maven/bin/mvnDebug /usr/local/bin/mvnDebug

ENV MAVEN_HOME=/opt/maven
ENV PATH="`${MAVEN_HOME}/bin:`${PATH}"

# 3. Persist env anche per login shell (/etc/profile.d sourced da zsh/bash)
RUN printf '%s\n' ``
        'export JAVA_HOME=/usr/local/java-21' ``
        'export MAVEN_HOME=/opt/maven' ``
        'export PATH="`$JAVA_HOME/bin:`$MAVEN_HOME/bin:`$PATH"' ``
        > /etc/profile.d/java-maven.sh ``
    && chmod +x /etc/profile.d/java-maven.sh

# 4. Smoke test: fallisce la build se qualcosa non va
RUN java -version 2>&1 && mvn --version && which java && which mvn

USER node
$MARKER_END
"@

    # Forza LF ovunque -- Docker legge il file in Linux
    $combined = ($content.TrimEnd() + ($patch -replace "`r`n", "`n")) -replace "`r`n", "`n"
    [System.IO.File]::WriteAllText($DOCKERFILE, $combined)

    Write-Ok "Dockerfile patchato ($DOCKERFILE): Java 21 + Maven $MAVEN_VERSION."
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
        Write-Ok "Nessun patch Java trovato in $DOCKERFILE. Niente da rimuovere."
        return
    }

    $result = ($kept -join "`n").TrimEnd() + "`n"
    [System.IO.File]::WriteAllText($DOCKERFILE, $result)
    Write-Ok "Blocco patch Java rimosso da $DOCKERFILE."
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

    Write-Host "  Patch Java applicato : " -NoNewline -ForegroundColor DarkGray
    if ([System.IO.File]::ReadAllText($DOCKERFILE).Contains($MARKER_BEGIN)) {
        $ver = [regex]::Match(
            [System.IO.File]::ReadAllText($DOCKERFILE),
            'maven-(\d+\.\d+\.\d+)'
        ).Groups[1].Value
        if (-not $ver) { $ver = '?' }
        Write-Host "si'  (Maven $ver)" -ForegroundColor Green
    } else {
        Write-Host "no   (.\patch-dockerfile-java.ps1 patch)" -ForegroundColor Yellow
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

  patch-dockerfile-java.ps1 -- aggiunge Java 21 + Maven al Dockerfile claudebox

  USO
    .\patch-dockerfile-java.ps1 [comando]

  COMANDI
    patch    Aggiunge Java 21 + Maven $MAVEN_VERSION (default, idempotente)
    remove   Rimuove il blocco patch
    status   Mostra lo stato corrente
    help     Mostra questo messaggio

  POSIZIONAMENTO CONSIGLIATO
    .devcontainer\patch-dockerfile-java.ps1
    -> claudebox lo esegue automaticamente dopo init/update e prima di up.

  VARIABILI AMBIENTE
    MAVEN_VERSION  Versione Maven (default: $MAVEN_VERSION)
    DOCKERFILE     Path al Dockerfile (override auto-discovery)

  WORKFLOW AUTOMATICO
    Copy-Item patch-dockerfile-java.ps1 .devcontainer\
    claudebox start -y

"@ -ForegroundColor White
}

# ── Entry point ────────────────────────────────────────────────────────────────
switch ($Command) {
    'remove' { Invoke-Remove }
    'status' { Show-Status  }
    'help'   { Show-Help    }
    default  { Invoke-Patch }   # '' o 'patch'
}
