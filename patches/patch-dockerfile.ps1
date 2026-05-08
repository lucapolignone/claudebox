#Requires -Version 5.1
<#
.SYNOPSIS
    patch-dockerfile.ps1 -- patch project-specific per claudebox (yougo-dev)

.DESCRIPTION
    Aggiunge al Dockerfile scaricato da claudebox:
      - PHP 8.x CLI + estensioni Symfony
      - Composer
      - mysql-client
    E permette di attaccare il container claudebox alla rete yougo-dev
    dello stack docker-compose (MySQL + Keycloak).

.PARAMETER Command
    patch   -> modifica .devcontainer/Dockerfile (idempotente, default)
    connect -> attacca il container claudebox alla rete yougo-dev
    status  -> mostra stato (patch/container/rete)
    help    -> mostra help

.PARAMETER Profile
    Profilo claudebox (default: 'work')

.EXAMPLE
    .\patch-dockerfile.ps1 patch
    .\patch-dockerfile.ps1 connect
    .\patch-dockerfile.ps1 connect -Profile work

.NOTES
    Workflow tipico (prima volta):
      1) claudebox init
      2) .\patch-dockerfile.ps1 patch
      3) docker compose up -d
      4) claudebox start -p work -y -n       (-n = no auto-update)
      5) .\patch-dockerfile.ps1 connect

    Claudebox riscarica il Dockerfile ad ogni 'init' e 'update'.
    Dopo quelle operazioni, ri-esegui 'patch'.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('patch','connect','status','help','')]
    [string]$Command = 'patch',

    [Parameter()]
    [Alias('p')]
    [string]$Profile = 'work'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Configurazione project ---------------------------------------------------
$NETWORK_NAME  = 'yougo-dev'
$DOCKERFILE    = '.devcontainer\Dockerfile'
$MARKER_BEGIN  = '# >>> CLAUDEBOX_PROJECT_PATCH_YOUGO_BEGIN >>>'
$MARKER_END    = '# <<< CLAUDEBOX_PROJECT_PATCH_YOUGO_END <<<'

# --- Output helpers -----------------------------------------------------------
function Write-Info ($msg) { Write-Host "  > $msg"  -ForegroundColor Cyan   }
function Write-Ok   ($msg) { Write-Host "  OK $msg" -ForegroundColor Green  }
function Write-Warn ($msg) { Write-Host "  !! $msg" -ForegroundColor Yellow }
function Write-Err  ($msg) { Write-Host "  ERR $msg" -ForegroundColor Red; exit 1 }

# --- Helpers (stessa logica di claudebox.ps1 per coerenza nomi) ---------------
function Get-ProjectName {
    (Split-Path -Leaf (Get-Location)) `
        -replace '[^a-zA-Z0-9_\-]', '-' `
        -replace '-+', '-' |
        ForEach-Object { $_.ToLower().Trim('-') }
}

function Get-ContainerName {
    $base = "claudebox-$(Get-ProjectName)"
    if ($Profile -ne 'personal' -and $Profile -ne '') {
        return "$base-$Profile"
    }
    return $base
}

# --- patch: aggiunge il blocco al Dockerfile (idempotente) --------------------
function Invoke-Patch {
    if (-not (Test-Path $DOCKERFILE)) {
        Write-Err "$DOCKERFILE non trovato. Esegui prima: claudebox init"
    }

    $content = Get-Content -LiteralPath $DOCKERFILE -Raw
    if ($content -match [regex]::Escape($MARKER_BEGIN)) {
        Write-Ok "Dockerfile gia' patchato (marker trovato). Niente da fare."
        Write-Info "Per riapplicare da zero: rimuovi il blocco tra '$MARKER_BEGIN' e '$MARKER_END'"
        return
    }

    # Backup una tantum (non sovrascrive se esiste gia')
    $backup = "$DOCKERFILE.orig"
    if (-not (Test-Path $backup)) {
        Copy-Item -LiteralPath $DOCKERFILE -Destination $backup
        Write-Ok "Backup salvato in $backup"
    }

    # NB: Dockerfile viene eseguito in Linux container -> servono line endings LF.
    # Costruiamo il blocco con `n e lo appendiamo preservando LF.
    $patchBlock = @"

$MARKER_BEGIN
# Aggiunte project-specific per yougo-dev:
#   - PHP 8.x CLI + estensioni richieste da Symfony
#   - Composer globale
#   - mysql-client (solo il client, il server sta nel compose)
# Applicare con: .\patch-dockerfile.ps1 patch
# Riapplicare dopo ogni 'claudebox init' o 'claudebox update'.

USER root

RUN apt-get update && apt-get install -y --no-install-recommends \
        php-cli \
        php-mbstring \
        php-intl \
        php-xml \
        php-curl \
        php-mysql \
        php-zip \
        php-bcmath \
        php-gd \
        php-sqlite3 \
        default-mysql-client \
        unzip \
    && rm -rf /var/lib/apt/lists/*

# Composer (ultima versione stabile, in /usr/local/bin/composer)
RUN php -r "copy('https://getcomposer.org/installer', '/tmp/composer-setup.php');" \
    && php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer \
    && rm /tmp/composer-setup.php \
    && chmod +x /usr/local/bin/composer

USER node

# Cartella cache Composer dell'utente 'node' (evita warning al primo 'composer install')
RUN mkdir -p /home/node/.composer && chown -R node:node /home/node/.composer
$MARKER_END
"@

    # Leggi contenuto esistente, append, riscrivi tutto con LF
    $existing = [System.IO.File]::ReadAllText((Resolve-Path $DOCKERFILE).Path)
    $combined = $existing + $patchBlock
    $lfOnly   = $combined -replace "`r`n", "`n"
    $bytes    = [System.Text.Encoding]::UTF8.GetBytes($lfOnly)
    [System.IO.File]::WriteAllBytes((Resolve-Path $DOCKERFILE).Path, $bytes)

    Write-Ok "Dockerfile patchato."
    Write-Info "Prossimo passo: claudebox start -p $Profile -y -n   (il flag -n evita il pin automatico)"
    Write-Info "In alternativa: claudebox up -p $Profile -n"
}

# --- connect: attacca il container claudebox alla rete yougo-dev --------------
function Invoke-Connect {
    $cname = Get-ContainerName

    $networks = docker network ls --format '{{.Name}}' 2>$null
    if ($networks -notcontains $NETWORK_NAME) {
        Write-Err "Rete '$NETWORK_NAME' non esiste. Avvia prima lo stack:  docker compose up -d"
    }

    $running = docker ps --format '{{.Names}}' 2>$null
    if ($running -notcontains $cname) {
        Write-Err "Container '$cname' non in esecuzione. Avvialo prima:  claudebox start -p $Profile -y -n"
    }

    # Controlla se gia' connesso
    $attached = docker inspect $cname `
        --format '{{range $k, $_ := .NetworkSettings.Networks}}{{$k}} {{end}}' 2>$null

    if ($attached -match "\b$NETWORK_NAME\b") {
        Write-Ok "Container '$cname' gia' connesso a '$NETWORK_NAME'"
    } else {
        docker network connect $NETWORK_NAME $cname
        if ($LASTEXITCODE -ne 0) {
            Write-Err "Fallita 'docker network connect $NETWORK_NAME $cname'"
        }
        Write-Ok "Connesso '$cname' a '$NETWORK_NAME'"
    }

    Write-Host ''
    Write-Host '  Dal container claudebox ora raggiungi:' -ForegroundColor White
    Write-Host '    mysql:3306     (user=yougo  pwd=yougo  db=yougo_new)' -ForegroundColor DarkGray
    Write-Host '    keycloak:8080' -ForegroundColor DarkGray
    Write-Host ''
    Write-Warn 'Le porte 8000 (Symfony) e 4200 (ng serve) NON sono pubblicate sull''host.'
    Write-Host '  Per raggiungerle dal browser:' -ForegroundColor White
    Write-Host '    - o modifichi claudebox.ps1 aggiungendo -p 8000:8000 -p 4200:4200 al docker run,' -ForegroundColor DarkGray
    Write-Host '    - o fai girare "php -S 0.0.0.0:8000" e "ng serve --host 0.0.0.0 --port 4200"' -ForegroundColor DarkGray
    Write-Host '      e accedi da un altro container nella stessa rete yougo-dev.' -ForegroundColor DarkGray
}

# --- status: stato corrente ---------------------------------------------------
function Invoke-Status {
    $cname = Get-ContainerName
    $proj  = Get-ProjectName

    Write-Host "  Project  : $proj"
    Write-Host "  Profile  : $Profile"
    Write-Host "  Container: $cname"
    Write-Host ''

    Write-Host '  Dockerfile patchato     : ' -NoNewline
    $patched = $false
    if (Test-Path $DOCKERFILE) {
        $c = Get-Content -LiteralPath $DOCKERFILE -Raw
        if ($c -match [regex]::Escape($MARKER_BEGIN)) { $patched = $true }
    }
    if ($patched) { Write-Host "si'" -ForegroundColor Green }
    else          { Write-Host 'no'  -ForegroundColor Yellow }

    Write-Host "  Rete $NETWORK_NAME esistente : " -NoNewline
    $networks = docker network ls --format '{{.Name}}' 2>$null
    if ($networks -contains $NETWORK_NAME) {
        Write-Host "si'" -ForegroundColor Green
    } else {
        Write-Host 'no (docker compose up -d)' -ForegroundColor Yellow
    }

    Write-Host '  Container claudebox up  : ' -NoNewline
    $running = docker ps --format '{{.Names}}' 2>$null
    $isUp = $running -contains $cname
    if ($isUp) { Write-Host "si'" -ForegroundColor Green }
    else       { Write-Host 'no'  -ForegroundColor Yellow }

    Write-Host "  Connesso a $NETWORK_NAME  : " -NoNewline
    if ($isUp) {
        $attached = docker inspect $cname `
            --format '{{range $k, $_ := .NetworkSettings.Networks}}{{$k}} {{end}}' 2>$null
        if ($attached -match "\b$NETWORK_NAME\b") {
            Write-Host "si'" -ForegroundColor Green
        } else {
            Write-Host 'no (.\patch-dockerfile.ps1 connect)' -ForegroundColor Yellow
        }
    } else {
        Write-Host 'n/a' -ForegroundColor DarkGray
    }
}

function Show-Help {
    Write-Host @"

  patch-dockerfile.ps1 -- customizzazioni project-specific per claudebox (yougo-dev)

  USO
    .\patch-dockerfile.ps1 [comando] [-Profile <nome>]

  COMANDI
    patch     Aggiunge PHP + Composer + mysql-client al Dockerfile (default, idempotente)
    connect   Attacca il container claudebox alla rete docker 'yougo-dev'
    status    Mostra lo stato corrente (patch applicato, container, rete)
    help      Mostra questo messaggio

  PARAMETRI
    -Profile  Profilo claudebox (default: 'work', alias: -p)

"@ -ForegroundColor White
}

# --- Entry point --------------------------------------------------------------
switch ($Command) {
    'patch'   { Invoke-Patch   }
    'connect' { Invoke-Connect }
    'status'  { Invoke-Status  }
    'help'    { Show-Help      }
    ''        { Invoke-Patch   }
    default   { Show-Help      }
}
