# GitLab credentials injection — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Aggiungere a `claudebox` (sh + ps1) un meccanismo opt-in per-profilo, persistente, di iniezione delle credenziali GitLab (`GITLAB_TOKEN` env var + bind mount RO di `~/.config/glab-cli/`) nel container, più una patch ufficiale `patch-dockerfile-glab` che installa il binario `glab` opt-in.

**Architecture:** File di config per-profilo in `~/.config/claudebox/<profilo>.conf` (formato `KEY=value`). Prompt interattivo a `init`/`start` con default `yes`, salvato in conf. `cmd_up` legge la conf e aggiunge condizionalmente `-v` (mount RO) e `-e GITLAB_TOKEN` al `docker run`. Pattern mount-then-copy simmetrico a `/host-claude` (mount RO + copia in `postStartCommand` + safety-net `docker exec`). La patch `glab` segue il pattern delle patch esistenti (`java`/`uvx`/`docker`).

**Tech Stack:** bash 3.2-compat (macOS), PowerShell 5+, BSD/GNU `sed`, Docker CLI.

**Spec di riferimento:** `docs/superpowers/specs/2026-05-11-gitlab-creds-injection-design.md`

**Note operative:**
- Il repo **non ha test suite automatica** (`CLAUDE.md`: "Niente backend, niente test"). La verifica di ogni task è manuale tramite `bash -n` (syntax check), `git diff`, e invocazioni mirate dello script.
- Ogni task contiene una sezione "Verify" con i comandi esatti da eseguire e l'output atteso.
- Commit dopo ogni task con Conventional Commits.

---

## Task 1: Helper functions profile-conf in `claudebox.sh`

**Files:**
- Modify: `/workspace/claudebox.sh:64-68` (inserire **dopo** la chiusura di `volume_suffix()` alla riga 68, prima del blocco "── Colori ──" della riga 70)

**Funzioni da aggiungere** (`profile_conf_path`, `profile_conf_get`, `profile_conf_set`).

- [ ] **Step 1: Backup di sicurezza**

```bash
cd /workspace
cp claudebox.sh claudebox.sh.task1.bak
```

- [ ] **Step 2: Aggiungere le tre funzioni dopo `volume_suffix()`**

Aprire `/workspace/claudebox.sh` e inserire, **dopo la riga 68** (chiusura di `volume_suffix()`) e **prima della riga 70** (`# ── Colori ──`), il blocco seguente:

```bash

# ── Profile config (~/.config/claudebox/<profilo>.conf) ───────────────────────
# Formato file: una riga per chiave nel formato KEY=value, niente apici, niente
# commenti. Usato per persistere preferenze utente per-profilo (es. opt-in di
# iniezione credenziali GitLab). File creato lazy alla prima scrittura.
profile_conf_path() {
    local prof="${1:-$PROFILE}"
    echo "$HOME/.config/claudebox/${prof}.conf"
}

# profile_conf_get KEY [DEFAULT] -- stampa il valore della chiave o DEFAULT se
# mancante. Silenzioso se il file non esiste o la chiave non e' definita.
profile_conf_get() {
    local key="$1" default="${2:-}"
    local conf
    conf="$(profile_conf_path)"
    if [ ! -f "$conf" ]; then
        printf '%s' "$default"
        return 0
    fi
    local line
    line=$(grep -E "^${key}=" "$conf" 2>/dev/null | head -1)
    if [ -z "$line" ]; then
        printf '%s' "$default"
    else
        # Strip "KEY=" prefix, mantieni il resto come valore
        printf '%s' "${line#${key}=}"
    fi
}

# profile_conf_set KEY VALUE -- crea dir+file se mancanti, sostituisce la
# chiave esistente o appende. BSD vs GNU sed gestito esplicitamente (macOS).
profile_conf_set() {
    local key="$1" value="$2"
    local conf
    conf="$(profile_conf_path)"
    local dir
    dir="$(dirname "$conf")"
    if ! mkdir -p "$dir" 2>/dev/null; then
        warn "Cannot create $dir, preference will not persist"
        return 1
    fi
    if [ ! -f "$conf" ]; then
        : > "$conf"
    fi
    if grep -qE "^${key}=" "$conf" 2>/dev/null; then
        # Sostituzione in-place: gestire BSD (macOS) vs GNU sed
        if sed --version 2>/dev/null | grep -q GNU; then
            sed -i "s|^${key}=.*|${key}=${value}|" "$conf"
        else
            sed -i '' "s|^${key}=.*|${key}=${value}|" "$conf"
        fi
    else
        printf '%s=%s\n' "$key" "$value" >> "$conf"
    fi
}
```

- [ ] **Step 3: Syntax check**

Run: `bash -n /workspace/claudebox.sh`
Expected: exit code 0, nessun output.

- [ ] **Step 4: Smoke test funzionale**

Run:
```bash
cd /workspace
rm -f ~/.config/claudebox/personal.conf
# Carica le funzioni in una subshell ed esegue uno scenario
bash -c '
    set -euo pipefail
    PROFILE=personal
    # FIX: serve un AUTO_YES e variabili colori per warn() in caso di errore
    AUTO_YES=false; RED=""; GREEN=""; YELLOW=""; CYAN=""; NC=""
    warn() { echo "WARN: $*" >&2; }
    source <(sed -n "/^# ── Profile config/,/^# ── Colori/p" claudebox.sh | head -n -1)

    echo "test1: get on missing file with default"
    val=$(profile_conf_get FOO bar)
    [ "$val" = "bar" ] || { echo "FAIL: $val"; exit 1; }
    echo "  OK: $val"

    echo "test2: set then get"
    profile_conf_set INJECT_GITLAB_CREDS yes
    val=$(profile_conf_get INJECT_GITLAB_CREDS)
    [ "$val" = "yes" ] || { echo "FAIL: $val"; exit 1; }
    echo "  OK: $val"

    echo "test3: update (set on existing key)"
    profile_conf_set INJECT_GITLAB_CREDS no
    val=$(profile_conf_get INJECT_GITLAB_CREDS)
    [ "$val" = "no" ] || { echo "FAIL: $val"; exit 1; }
    echo "  OK: $val"

    echo "test4: file contents (single line)"
    cat ~/.config/claudebox/personal.conf
    [ "$(wc -l < ~/.config/claudebox/personal.conf)" -eq 1 ] || { echo "FAIL: multi-line"; exit 1; }
    echo "  OK: single line"

    echo "test5: append a second key"
    profile_conf_set OTHER_KEY hello
    val=$(profile_conf_get OTHER_KEY)
    [ "$val" = "hello" ] || { echo "FAIL: $val"; exit 1; }
    echo "  OK: $val"

    echo "ALL TESTS PASSED"
'
```

Expected: ultima riga "ALL TESTS PASSED".

Se il test fallisce con "source: command not found" o problemi simili, l'utente esegue manualmente: copia/incolla le tre funzioni in una shell interattiva insieme a `PROFILE=personal; warn() { echo "$*" >&2; }`, poi i 5 test.

- [ ] **Step 5: Cleanup del file di test e del backup**

```bash
rm -f ~/.config/claudebox/personal.conf
rm -f /workspace/claudebox.sh.task1.bak
```

- [ ] **Step 6: Commit**

```bash
cd /workspace
git add claudebox.sh
git -c user.email=luca.polignone@youtilitycenter.it -c user.name="Luca Polignone" \
    commit -m "feat(sh): add per-profile config helpers (profile_conf_get/set)

Helpers to read/write ~/.config/claudebox/<profile>.conf in KEY=value
format. Will be used by upcoming GitLab credentials injection prompt.

BSD vs GNU sed gated explicitly for macOS compatibility."
```

---

## Task 2: Helper functions profile-conf in `claudebox.ps1`

**Files:**
- Modify: `/workspace/claudebox.ps1:68-71` (inserire **dopo** la chiusura di `Get-VolumeSuffix` alla riga 71, prima della riga 73 `# --- Colori`)

- [ ] **Step 1: Backup**

```bash
cp /workspace/claudebox.ps1 /workspace/claudebox.ps1.task2.bak
```

- [ ] **Step 2: Aggiungere le tre funzioni**

In `/workspace/claudebox.ps1`, **dopo la riga 71** (chiusura di `function Get-VolumeSuffix`) e **prima della riga 73** (`# --- Colori`), inserire:

```powershell

# --- Profile config (~/.config/claudebox/<profilo>.conf) -----------------------
# Formato KEY=value, una chiave per riga, niente apici, niente commenti. Equiv.
# delle funzioni bash profile_conf_* di claudebox.sh.
function Get-ProfileConfPath ([string]$Prof = $script:Profile) {
    if ([string]::IsNullOrEmpty($Prof)) { $Prof = 'personal' }
    return Join-Path $env:USERPROFILE ".config\claudebox\$Prof.conf"
}

function Get-ProfileConfValue ([string]$Key, [string]$Default = '') {
    $conf = Get-ProfileConfPath
    if (-not (Test-Path -LiteralPath $conf)) { return $Default }
    $line = Get-Content -LiteralPath $conf -Encoding UTF8 |
        Where-Object { $_ -match "^$([regex]::Escape($Key))=" } |
        Select-Object -First 1
    if (-not $line) { return $Default }
    return $line.Substring($Key.Length + 1)
}

function Set-ProfileConfValue ([string]$Key, [string]$Value) {
    $conf = Get-ProfileConfPath
    $dir  = Split-Path -Parent $conf
    if (-not (Test-Path -LiteralPath $dir)) {
        try { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        catch { Write-Warn "Cannot create $dir, preference will not persist"; return }
    }
    if (-not (Test-Path -LiteralPath $conf)) {
        Set-Content -LiteralPath $conf -Value '' -Encoding UTF8 -NoNewline
    }
    $lines = @(Get-Content -LiteralPath $conf -Encoding UTF8)
    $pattern = "^$([regex]::Escape($Key))="
    $found = $false
    $newLines = $lines | ForEach-Object {
        if ($_ -match $pattern) { $found = $true; "$Key=$Value" } else { $_ }
    }
    if (-not $found) { $newLines = @($newLines | Where-Object { $_ -ne '' }) + "$Key=$Value" }
    # LF line endings, UTF-8 no BOM
    $body = ($newLines -join "`n") + "`n"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
    [System.IO.File]::WriteAllBytes($conf, $bytes)
}
```

- [ ] **Step 3: Syntax check**

Su una macchina Windows o con PowerShell installato:
```powershell
powershell -NoProfile -Command "& { . /workspace/claudebox.ps1 -Command help } 2>&1 | Select-Object -First 5"
```

Se PowerShell non è disponibile (es. dentro al devcontainer Linux), saltare lo step e segnalarlo nel commit message. Il syntax check verrà ripetuto dall'utente prima del merge.

- [ ] **Step 4: Cleanup backup**

```bash
rm -f /workspace/claudebox.ps1.task2.bak
```

- [ ] **Step 5: Commit**

```bash
cd /workspace
git add claudebox.ps1
git -c user.email=luca.polignone@youtilitycenter.it -c user.name="Luca Polignone" \
    commit -m "feat(ps1): add per-profile config helpers (Get/Set-ProfileConfValue)

PowerShell parity with the bash helpers added in the previous commit:
Get-ProfileConfPath / Get-ProfileConfValue / Set-ProfileConfValue.

Uses UTF-8 no-BOM with LF line endings to match the bash side."
```

---

## Task 3: Prompt + wiring in `claudebox.sh`

**Files:**
- Modify: `/workspace/claudebox.sh` — aggiungere `ensure_gitlab_creds_choice` subito dopo le helper aggiunte al Task 1; chiamarla in `cmd_init` (prima di `run_dockerfile_patches`, riga 409) e in `cmd_start` (subito dopo la chiusura del blocco "Ask about update" intorno alla riga 798).

- [ ] **Step 1: Aggiungere `ensure_gitlab_creds_choice`**

Subito dopo la funzione `profile_conf_set` aggiunta nel Task 1, aggiungere:

```bash

# Chiede una volta sola se iniettare le credenziali GitLab dell'host e salva la
# scelta nel file di config del profilo. Default = yes. In non-TTY (pipe/CI) o
# con -y, salva il default senza prompt.
ensure_gitlab_creds_choice() {
    local current
    current=$(profile_conf_get INJECT_GITLAB_CREDS)
    if [ -n "$current" ]; then
        return 0
    fi

    if [ ! -t 0 ]; then
        profile_conf_set INJECT_GITLAB_CREDS yes
        return 0
    fi

    # read_input_or_default rispetta gia' $AUTO_YES (vedi claudebox.sh:53)
    local answer
    answer=$(read_input_or_default \
        "  Inject host GitLab credentials (\$GITLAB_TOKEN + ~/.config/glab-cli) into the container? [Y/n]: " \
        "yes")
    local lower
    lower=$(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]')
    case "$lower" in
        n|no) profile_conf_set INJECT_GITLAB_CREDS no ;;
        *)    profile_conf_set INJECT_GITLAB_CREDS yes ;;
    esac
}
```

- [ ] **Step 2: Wire in `cmd_init`**

Localizzare la riga `run_dockerfile_patches "$(pwd)"` in `cmd_init` (attualmente `/workspace/claudebox.sh:409`). Inserire la chiamata **immediatamente prima**:

Da:
```bash
    # Apply project-specific Dockerfile patches (idempotent, see README)
    run_dockerfile_patches "$(pwd)"
```

A:
```bash
    # Chiedere preferenza iniezione credenziali GitLab (persistita per profilo)
    ensure_gitlab_creds_choice

    # Apply project-specific Dockerfile patches (idempotent, see README)
    run_dockerfile_patches "$(pwd)"
```

- [ ] **Step 3: Wire in `cmd_start`**

Localizzare in `cmd_start` la chiusura del blocco "Ask about update if .devcontainer already exists" (attualmente `/workspace/claudebox.sh:786-798`). Subito **dopo** la riga 798 (`fi` di chiusura del `if $has_devcontainer; then ... fi`) e **prima** della riga 800 (`# Current state`), inserire:

```bash

    # Chiedere preferenza iniezione credenziali GitLab al primo start del profilo
    ensure_gitlab_creds_choice
```

- [ ] **Step 4: Syntax check**

```bash
bash -n /workspace/claudebox.sh && echo "OK"
```
Expected: `OK`.

- [ ] **Step 5: Smoke test del prompt in non-TTY (default auto-yes)**

```bash
rm -f ~/.config/claudebox/personal.conf
# Simuliamo: forziamo lo stub di read_input_or_default e chiamiamo ensure_*
# in modalita' non-tty (stdin chiuso). Deve persistere "yes" senza prompt.
bash -c '
    set -euo pipefail
    PROFILE=personal; AUTO_YES=false
    RED=""; GREEN=""; YELLOW=""; CYAN=""; NC=""
    warn() { echo "WARN: $*" >&2; }
    read_input_or_default() { echo "$2"; }
    # Carica helper + ensure_gitlab_creds_choice
    eval "$(sed -n "/^profile_conf_path()/,/^ensure_gitlab_creds_choice() {$/p" claudebox.sh)"
    eval "$(sed -n "/^ensure_gitlab_creds_choice() {$/,/^}$/p" claudebox.sh)"
    ensure_gitlab_creds_choice </dev/null
    val=$(profile_conf_get INJECT_GITLAB_CREDS)
    [ "$val" = "yes" ] || { echo "FAIL: got $val"; exit 1; }
    echo "OK (non-TTY default: yes)"
'
```
Expected: `OK (non-TTY default: yes)`.

Cleanup: `rm -f ~/.config/claudebox/personal.conf`

- [ ] **Step 6: Commit**

```bash
cd /workspace
git add claudebox.sh
git -c user.email=luca.polignone@youtilitycenter.it -c user.name="Luca Polignone" \
    commit -m "feat(sh): add GitLab credentials opt-in prompt

ensure_gitlab_creds_choice prompts once per profile (default yes), then
persists the answer to ~/.config/claudebox/<profile>.conf via the helpers
added previously. Called from cmd_init (before run_dockerfile_patches)
and cmd_start (after the update prompt)."
```

---

## Task 4: Prompt + wiring in `claudebox.ps1`

**Files:**
- Modify: `/workspace/claudebox.ps1` — aggiungere `Ensure-GitlabCredsChoice` dopo le helper del Task 2; chiamarla in `Invoke-Init` (prima della riga `Invoke-DockerfilePatches`, attualmente riga 500) e in `Invoke-Start` (subito dopo il blocco "update?", intorno alla riga 922).

- [ ] **Step 1: Aggiungere `Ensure-GitlabCredsChoice`**

Subito dopo `Set-ProfileConfValue` (aggiunta al Task 2), inserire:

```powershell

# Chiede una volta sola se iniettare le credenziali GitLab e salva nel conf
# del profilo. Default yes. In non-TTY o con -y, salva default senza prompt.
function Ensure-GitlabCredsChoice {
    $current = Get-ProfileConfValue 'INJECT_GITLAB_CREDS'
    if (-not [string]::IsNullOrEmpty($current)) { return }

    # Non-interattivo (host script, redirection): salva default
    if (-not [Environment]::UserInteractive -or -not $Host.UI.RawUI) {
        Set-ProfileConfValue 'INJECT_GITLAB_CREDS' 'yes'
        return
    }

    # Read-InputOrDefault rispetta gia' $AutoYes (claudebox.ps1:57)
    $answer = Read-InputOrDefault "  Inject host GitLab credentials (`$GITLAB_TOKEN + ~/.config/glab-cli) into the container? [Y/n]" "yes"
    switch (($answer + '').ToLower()) {
        'n'  { Set-ProfileConfValue 'INJECT_GITLAB_CREDS' 'no' }
        'no' { Set-ProfileConfValue 'INJECT_GITLAB_CREDS' 'no' }
        default { Set-ProfileConfValue 'INJECT_GITLAB_CREDS' 'yes' }
    }
}
```

- [ ] **Step 2: Wire in `Invoke-Init`**

Localizzare in `Invoke-Init` la riga `Invoke-DockerfilePatches -ProjectRoot (Get-Location).Path` (attualmente `/workspace/claudebox.ps1:500`). Inserire **immediatamente prima**:

```powershell
    # Chiedere preferenza iniezione credenziali GitLab (persistita per profilo)
    Ensure-GitlabCredsChoice

```

(con linea vuota di separazione dopo).

- [ ] **Step 3: Wire in `Invoke-Start`**

Localizzare in `Invoke-Start` la chiusura del blocco "Decide whether to update" (attualmente la riga `}` che chiude `if ($hasDevcontainer) { ... }`, intorno a `/workspace/claudebox.ps1:922`). Subito **dopo** quella `}` e **prima** della riga `Write-Host ""` che precede "Current state" (riga 924), inserire:

```powershell

    # Chiedere preferenza iniezione credenziali GitLab al primo start del profilo
    Ensure-GitlabCredsChoice
```

- [ ] **Step 4: Commit**

```bash
cd /workspace
git add claudebox.ps1
git -c user.email=luca.polignone@youtilitycenter.it -c user.name="Luca Polignone" \
    commit -m "feat(ps1): add GitLab credentials opt-in prompt

PowerShell parity with the bash side: Ensure-GitlabCredsChoice prompts
once per profile and persists the answer. Called from Invoke-Init and
Invoke-Start."
```

---

## Task 5: `cmd_up` injection + devcontainer.json template in `claudebox.sh`

**Files:**
- Modify: `/workspace/claudebox.sh` — (a) `cmd_init` template di `devcontainer.json` riga 385 estende `postStartCommand`; (b) `cmd_up` riga 535 aggiunge il blocco di iniezione subito dopo il blocco DooD; (c) `cmd_up` aggiunge il safety-net `docker exec` subito dopo il blocco `chgrp docker` esistente (intorno alla riga 585).

- [ ] **Step 1: Estendere `postStartCommand` nel template `devcontainer.json`**

In `cmd_init`, la riga 385 (lunghissima, contiene `"postStartCommand": "sudo chown ... init-firewall.sh 2>/dev/null || true"`). Modificarla **aggiungendo** il blocco di copia glab. Il punto di inserimento è subito **prima** del `&& sudo /usr/local/bin/init-firewall.sh 2>/dev/null || true` finale (cioè all'inizio della catena `&&`, mantenendo l'init-firewall come ultimo step).

La riga 385 originale è:

```
  "postStartCommand": "sudo chown -R node:node /home/node/.claude /home/node/.config && mkdir -p /home/node/.local/bin /home/node/.config/ccstatusline /home/node/.claude/plugins && if [ ! -f /home/node/.claude/.credentials.json ]; then cp -rn /host-claude/. /home/node/.claude/ 2>/dev/null || true; fi && cp -rn /host-claude-plugins/. /home/node/.claude/plugins/ 2>/dev/null || true && if [ ! -f /home/node/.config/ccstatusline/settings.json ]; then cp -rn /host-ccstatusline/. /home/node/.config/ccstatusline/ 2>/dev/null || true; fi && sudo /usr/local/bin/init-firewall.sh 2>/dev/null || true",
```

Sostituirla con (nuovo blocco glab inserito **prima** del `&& sudo /usr/local/bin/init-firewall.sh`):

```
  "postStartCommand": "sudo chown -R node:node /home/node/.claude /home/node/.config && mkdir -p /home/node/.local/bin /home/node/.config/ccstatusline /home/node/.claude/plugins && if [ ! -f /home/node/.claude/.credentials.json ]; then cp -rn /host-claude/. /home/node/.claude/ 2>/dev/null || true; fi && cp -rn /host-claude-plugins/. /home/node/.claude/plugins/ 2>/dev/null || true && if [ ! -f /home/node/.config/ccstatusline/settings.json ]; then cp -rn /host-ccstatusline/. /home/node/.config/ccstatusline/ 2>/dev/null || true; fi && mkdir -p /home/node/.config/glab-cli && if [ -d /host-glab-cli ]; then cp -rn /host-glab-cli/. /home/node/.config/glab-cli/ 2>/dev/null || true; fi && sudo /usr/local/bin/init-firewall.sh 2>/dev/null || true",
```

(differenza: aggiunti `&& mkdir -p /home/node/.config/glab-cli && if [ -d /host-glab-cli ]; then cp -rn /host-glab-cli/. /home/node/.config/glab-cli/ 2>/dev/null || true; fi` prima di `&& sudo /usr/local/bin/init-firewall.sh`).

- [ ] **Step 2: Aggiungere il blocco di iniezione in `cmd_up`**

In `cmd_up`, localizzare il blocco DooD che termina alla riga 535 (`fi` di chiusura di `if [ -f ".devcontainer/Dockerfile" ] && grep -qF "CLAUDEBOX_PATCH_DOCKER_BEGIN" ...`). Inserire **subito dopo** quel `fi` (riga 535) e **prima** del commento `# Start container` (riga 537), il blocco:

```bash

    # GitLab credentials injection (opt-in per-profile, see profile conf)
    local inject_glab
    inject_glab=$(profile_conf_get INJECT_GITLAB_CREDS no)
    if [ "$inject_glab" = "yes" ]; then
        local glab_dir="$HOME/.config/glab-cli"
        local has_dir=0 has_token=0
        if [ -d "$glab_dir" ]; then
            docker_extra_opts+=( -v "${glab_dir}:/host-glab-cli:ro" )
            has_dir=1
        fi
        if [ -n "${GITLAB_TOKEN:-}" ]; then
            docker_extra_opts+=( -e "GITLAB_TOKEN=${GITLAB_TOKEN}" )
            has_token=1
        fi
        if [ "$has_dir" = "1" ] || [ "$has_token" = "1" ]; then
            local _hd _ht
            [ "$has_dir"   = "1" ] && _hd=yes || _hd=no
            [ "$has_token" = "1" ] && _ht=yes || _ht=no
            info "GitLab credentials injected (glab-cli config: $_hd, GITLAB_TOKEN env: $_ht)"
        else
            warn "INJECT_GITLAB_CREDS=yes but neither \$GITLAB_TOKEN nor ~/.config/glab-cli/ available on host — skipping"
        fi
    fi
```

- [ ] **Step 3: Aggiungere il safety-net `docker exec` post-start**

In `cmd_up`, localizzare il blocco DooD di post-start "Docker.sock alignment" che termina intorno alla riga 585 (`fi` di chiusura del `if docker exec -u root "$cname" bash -c ... ; then ... fi`). Inserire **subito dopo** quel blocco di chiusura (riga 585) e **prima** del commento `# Copy config on first start` (riga 587), il safety-net:

```bash

    # GitLab credentials post-start copy (safety-net per devcontainer.json
    # generati da claudebox precedenti, che non hanno la copia in postStartCommand).
    # Idempotente: cp -rn no-clobber, e l'intero blocco e' eseguito solo se
    # l'utente ha optato per l'iniezione.
    if [ "${inject_glab:-no}" = "yes" ]; then
        docker exec -u node "$cname" bash -c \
            'mkdir -p /home/node/.config/glab-cli && \
             if [ -d /host-glab-cli ]; then \
                 cp -rn /host-glab-cli/. /home/node/.config/glab-cli/ 2>/dev/null || true; \
             fi' >/dev/null 2>&1 || true
    fi
```

- [ ] **Step 4: Syntax check**

```bash
bash -n /workspace/claudebox.sh && echo "OK"
```
Expected: `OK`.

- [ ] **Step 5: Verifica visiva del diff**

```bash
cd /workspace
git diff claudebox.sh | head -120
```
Expected: 3 hunk distinti — uno sulla riga ~385 (postStartCommand allungato), uno sulla riga ~535 (blocco GitLab injection), uno sulla riga ~585 (safety-net docker exec).

- [ ] **Step 6: Commit**

```bash
cd /workspace
git add claudebox.sh
git -c user.email=luca.polignone@youtilitycenter.it -c user.name="Luca Polignone" \
    commit -m "feat(sh): inject GitLab credentials into container when opt-in

cmd_up now conditionally adds -v ~/.config/glab-cli:/host-glab-cli:ro
and -e GITLAB_TOKEN to docker run when the per-profile conf says yes.
postStartCommand in the generated devcontainer.json copies the mounted
config to /home/node/.config/glab-cli/. A docker exec safety-net covers
users whose devcontainer.json predates this change."
```

---

## Task 6: `Invoke-Up` injection + devcontainer.json template in `claudebox.ps1`

**Files:**
- Modify: `/workspace/claudebox.ps1` — (a) template `$devcontainerJson` riga 468 estende `postStartCommand`; (b) `Invoke-Up` aggiunge il blocco di iniezione subito dopo il blocco DooD (intorno alla riga 646); (c) `Invoke-Up` aggiunge il safety-net `docker exec` dentro il try/catch del firewall (intorno alla riga 680).

- [ ] **Step 1: Estendere `postStartCommand` nel template**

Aprire `/workspace/claudebox.ps1` e localizzare la riga 468 (template `postStartCommand`). Sostituirla con la versione estesa identica al Task 5 Step 1 (aggiunta della catena glab prima di `&& sudo /usr/local/bin/init-firewall.sh`):

Riga originale (468):
```
  "postStartCommand": "sudo chown -R node:node /home/node/.claude /home/node/.config && mkdir -p /home/node/.local/bin /home/node/.config/ccstatusline /home/node/.claude/plugins && if [ ! -f /home/node/.claude/.credentials.json ]; then cp -rn /host-claude/. /home/node/.claude/ 2>/dev/null || true; fi && cp -rn /host-claude-plugins/. /home/node/.claude/plugins/ 2>/dev/null || true && if [ ! -f /home/node/.config/ccstatusline/settings.json ]; then cp -rn /host-ccstatusline/. /home/node/.config/ccstatusline/ 2>/dev/null || true; fi && sudo /usr/local/bin/init-firewall.sh 2>/dev/null || true",
```

Sostituire con:
```
  "postStartCommand": "sudo chown -R node:node /home/node/.claude /home/node/.config && mkdir -p /home/node/.local/bin /home/node/.config/ccstatusline /home/node/.claude/plugins && if [ ! -f /home/node/.claude/.credentials.json ]; then cp -rn /host-claude/. /home/node/.claude/ 2>/dev/null || true; fi && cp -rn /host-claude-plugins/. /home/node/.claude/plugins/ 2>/dev/null || true && if [ ! -f /home/node/.config/ccstatusline/settings.json ]; then cp -rn /host-ccstatusline/. /home/node/.config/ccstatusline/ 2>/dev/null || true; fi && mkdir -p /home/node/.config/glab-cli && if [ -d /host-glab-cli ]; then cp -rn /host-glab-cli/. /home/node/.config/glab-cli/ 2>/dev/null || true; fi && sudo /usr/local/bin/init-firewall.sh 2>/dev/null || true",
```

- [ ] **Step 2: Aggiungere il blocco di iniezione in `Invoke-Up`**

Localizzare in `Invoke-Up` la fine del blocco DooD (`}` che chiude `if (Test-Path -LiteralPath $dockerfilePath) { ... }`, intorno a `/workspace/claudebox.ps1:646`). **Subito dopo** quella `}` e **prima** del commento `# -- Avvia container --` (riga ~648), inserire:

```powershell

    # -- GitLab credentials injection (opt-in per-profile) ---------------------
    $injectGlab = Get-ProfileConfValue 'INJECT_GITLAB_CREDS' 'no'
    if ($injectGlab -eq 'yes') {
        $glabDir = Join-Path $env:USERPROFILE ".config\glab-cli"
        $hasDir   = Test-Path -LiteralPath $glabDir
        $hasToken = -not [string]::IsNullOrEmpty($env:GITLAB_TOKEN)
        if ($hasDir) {
            # Docker Desktop su Windows accetta bind mount con sintassi POSIX
            $glabDirDocker = $glabDir -replace '\\', '/'
            $dockerExtraOpts += @('-v', "${glabDirDocker}:/host-glab-cli:ro")
        }
        if ($hasToken) {
            $dockerExtraOpts += @('-e', "GITLAB_TOKEN=$env:GITLAB_TOKEN")
        }
        if ($hasDir -or $hasToken) {
            $dirYn   = if ($hasDir)   { 'yes' } else { 'no' }
            $tokenYn = if ($hasToken) { 'yes' } else { 'no' }
            Write-Info "GitLab credentials injected (glab-cli config: $dirYn, GITLAB_TOKEN env: $tokenYn)"
        } else {
            Write-Warn "INJECT_GITLAB_CREDS=yes but neither `$GITLAB_TOKEN nor ~/.config/glab-cli/ available on host -- skipping"
        }
    }
```

- [ ] **Step 3: Aggiungere il safety-net `docker exec`**

In `Invoke-Up`, localizzare il blocco di copia ccstatusline esistente alla riga ~680 (`docker exec $cname bash -c 'mkdir -p /home/node/.config/ccstatusline ...'`). **Subito dopo** quella riga (mantenendo l'allineamento al try block) e **prima** del commento `# Fix host paths` (riga ~681), inserire:

```powershell
        # GitLab credentials post-start copy (safety-net per devcontainer.json
        # generati da claudebox precedenti, che non hanno la copia in postStartCommand)
        if ($injectGlab -eq 'yes') {
            docker exec -u node $cname bash -c 'mkdir -p /home/node/.config/glab-cli && if [ -d /host-glab-cli ]; then cp -rn /host-glab-cli/. /home/node/.config/glab-cli/ 2>/dev/null || true; fi' 2>$null | Out-Null
        }
```

- [ ] **Step 4: Verifica del diff**

```bash
cd /workspace
git diff claudebox.ps1 | head -100
```
Expected: 3 hunk — postStartCommand esteso, blocco injection dopo DooD, safety-net dopo copia ccstatusline.

- [ ] **Step 5: Commit**

```bash
cd /workspace
git add claudebox.ps1
git -c user.email=luca.polignone@youtilitycenter.it -c user.name="Luca Polignone" \
    commit -m "feat(ps1): inject GitLab credentials into container when opt-in

PowerShell parity with the bash side. Bind mount RO of ~/.config/glab-cli
(host) + pass-through GITLAB_TOKEN env var. Path conversion to POSIX form
for Docker Desktop compatibility on Windows."
```

---

## Task 7: Patch `patches/patch-dockerfile-glab.sh`

**Files:**
- Create: `/workspace/patches/patch-dockerfile-glab.sh`

- [ ] **Step 1: Creare il file**

Scrivere `/workspace/patches/patch-dockerfile-glab.sh` con il seguente contenuto esatto:

```bash
#!/usr/bin/env bash
# patch-dockerfile-glab.sh -- aggiunge la CLI glab (GitLab) al Dockerfile claudebox
#
# USO:
#   ./patch-dockerfile-glab.sh              # applica (idempotente)
#   ./patch-dockerfile-glab.sh patch        # idem
#   ./patch-dockerfile-glab.sh remove       # rimuove il blocco
#   ./patch-dockerfile-glab.sh status       # stato corrente
#
# POSIZIONAMENTO:
#   - .devcontainer/patch-dockerfile-glab.sh   (preferito)
#   - ./patch-dockerfile-glab.sh               (project root)
#
# COSA INSTALLA:
#   - /usr/local/bin/glab (GitLab CLI, https://gitlab.com/gitlab-org/cli)
#
# METODO:
#   Scarica il tarball release ufficiale (linux_x86_64 o linux_arm64) dalla
#   pagina releases del progetto e installa il binario in /usr/local/bin.
#
# VARIABILI AMBIENTE:
#   GLAB_VERSION   Versione di glab da installare (default: 1.49.0)
#                  Es: '1.49.0', '1.50.0'
#                  Pinna a una versione specifica per build riproducibili.
#   DOCKERFILE     Path al Dockerfile (override auto-discovery)

set -euo pipefail

# ── Configurazione ─────────────────────────────────────────────────────────────
GLAB_VERSION="${GLAB_VERSION:-1.49.0}"
MARKER_BEGIN="# >>> CLAUDEBOX_PATCH_GLAB_BEGIN >>>"
MARKER_END="# <<< CLAUDEBOX_PATCH_GLAB_END <<<"

# ── Output helpers ─────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "  ${CYAN}>${NC} $*"; }
ok()   { echo -e "  ${GREEN}OK${NC} $*"; }
warn() { echo -e "  ${YELLOW}!!${NC} $*"; }
err()  { echo -e "  ${RED}ERR${NC} $*" >&2; exit 1; }

# ── Dockerfile discovery ───────────────────────────────────────────────────────
find_dockerfile() {
    local candidates=(
        "${DOCKERFILE:-}"
        "Dockerfile"
        ".devcontainer/Dockerfile"
    )
    local c
    for c in "${candidates[@]}"; do
        [ -z "$c" ] && continue
        if [ -f "$c" ]; then
            printf '%s' "$c"
            return 0
        fi
    done
    return 1
}

DOCKERFILE="$(find_dockerfile || true)"

# ── patch ──────────────────────────────────────────────────────────────────────
cmd_patch() {
    [ -n "$DOCKERFILE" ] || err "Dockerfile non trovato (cercato in ./Dockerfile e ./.devcontainer/Dockerfile). Esegui prima: claudebox init"

    if grep -qF "$MARKER_BEGIN" "$DOCKERFILE"; then
        ok "Patch glab gia' presente in $DOCKERFILE. Niente da fare."
        return 0
    fi

    if [ ! -f "${DOCKERFILE}.orig" ]; then
        cp "$DOCKERFILE" "${DOCKERFILE}.orig"
        ok "Backup in ${DOCKERFILE}.orig"
    fi

    cat >> "$DOCKERFILE" <<EOF

$MARKER_BEGIN
# GitLab CLI 'glab' v${GLAB_VERSION}
# Aggiunto da patch-dockerfile-glab.sh -- riapplicato automaticamente da claudebox.
# Metodo: download binario dal release ufficiale (GitLab Releases) e install in
# /usr/local/bin. Funziona su amd64 e arm64.

USER root

ARG GLAB_VERSION=${GLAB_VERSION}
RUN set -eux; \\
    arch="\$(dpkg --print-architecture)"; \\
    case "\$arch" in \\
        amd64) glab_arch="x86_64" ;; \\
        arm64) glab_arch="arm64" ;; \\
        *) echo "unsupported arch: \$arch" >&2; exit 1 ;; \\
    esac; \\
    curl -fsSL -o /tmp/glab.tgz \\
        "https://gitlab.com/gitlab-org/cli/-/releases/v\${GLAB_VERSION}/downloads/glab_\${GLAB_VERSION}_linux_\${glab_arch}.tar.gz"; \\
    tar -xzf /tmp/glab.tgz -C /tmp; \\
    install -m 0755 /tmp/bin/glab /usr/local/bin/glab; \\
    rm -rf /tmp/glab.tgz /tmp/bin /tmp/LICENSE /tmp/README.md 2>/dev/null || true; \\
    glab --version

USER node
$MARKER_END
EOF

    ok "Dockerfile patchato ($DOCKERFILE): glab v${GLAB_VERSION}."
}

# ── remove ─────────────────────────────────────────────────────────────────────
cmd_remove() {
    [ -n "$DOCKERFILE" ] || err "Dockerfile non trovato."

    if ! grep -qF "$MARKER_BEGIN" "$DOCKERFILE"; then
        ok "Nessun patch glab trovato in $DOCKERFILE. Niente da rimuovere."
        return 0
    fi

    if sed --version 2>/dev/null | grep -q GNU; then
        sed -i "/^${MARKER_BEGIN}$/,/^${MARKER_END}$/d" "$DOCKERFILE"
    else
        sed -i '' "/^${MARKER_BEGIN}$/,/^${MARKER_END}$/d" "$DOCKERFILE"
    fi

    ok "Blocco patch glab rimosso da $DOCKERFILE."
}

# ── status ─────────────────────────────────────────────────────────────────────
cmd_status() {
    echo ""
    echo -n "  Dockerfile trovato   : "
    if [ -n "$DOCKERFILE" ]; then
        echo -e "${GREEN}si'${NC}  ($DOCKERFILE)"
    else
        echo -e "${YELLOW}no${NC}  (claudebox init non ancora eseguito)"
        echo ""
        return
    fi

    echo -n "  Patch glab applicato : "
    if grep -qF "$MARKER_BEGIN" "$DOCKERFILE"; then
        local ver
        ver=$(grep -oE 'ARG GLAB_VERSION=[a-zA-Z0-9._-]+' "$DOCKERFILE" | head -1 | cut -d= -f2 || echo "?")
        echo -e "${GREEN}si'${NC}  (glab $ver)"
    else
        echo -e "${YELLOW}no${NC}  (./patch-dockerfile-glab.sh patch)"
    fi

    echo -n "  Backup orig presente : "
    if [ -f "${DOCKERFILE}.orig" ]; then
        echo -e "${GREEN}si'${NC}  (${DOCKERFILE}.orig)"
    else
        echo -e "${YELLOW}no${NC}"
    fi
    echo ""
}

# ── help ───────────────────────────────────────────────────────────────────────
cmd_help() {
    cat <<HELP

  patch-dockerfile-glab.sh -- aggiunge la CLI glab al Dockerfile claudebox

  USO
    ./patch-dockerfile-glab.sh [comando]

  COMANDI
    patch    Aggiunge glab (default, idempotente)
    remove   Rimuove il blocco patch
    status   Mostra lo stato corrente
    help     Mostra questo messaggio

  POSIZIONAMENTO CONSIGLIATO
    .devcontainer/patch-dockerfile-glab.sh
    -> claudebox lo esegue automaticamente dopo init/update e prima di up.

  VARIABILI AMBIENTE
    GLAB_VERSION   Versione glab (default: 1.49.0)
                   Pinna a una versione specifica per build riproducibili.
    DOCKERFILE     Path al Dockerfile (override auto-discovery)

  COSA OTTIENI NEL CONTAINER
    glab           CLI ufficiale GitLab (clone, MR, issue, CI, ecc.)
                   Es: glab mr list
                       glab issue create
                       glab ci view

  AUTENTICAZIONE
    Per autenticare glab nel container, claudebox puo' iniettare le credenziali
    GitLab dell'host (\$GITLAB_TOKEN env var + ~/.config/glab-cli/ in RO).
    L'opt-in viene chiesto a 'claudebox init' o 'claudebox start'.

HELP
}

# ── Entry point ────────────────────────────────────────────────────────────────
case "${1:-patch}" in
    patch)   cmd_patch  ;;
    remove)  cmd_remove ;;
    status)  cmd_status ;;
    help|-h|--help) cmd_help ;;
    *) err "Comando sconosciuto: $1  (usa: patch | remove | status | help)" ;;
esac
```

- [ ] **Step 2: Rendere eseguibile**

```bash
chmod +x /workspace/patches/patch-dockerfile-glab.sh
```

- [ ] **Step 3: Syntax check**

```bash
bash -n /workspace/patches/patch-dockerfile-glab.sh && echo "OK"
```
Expected: `OK`.

- [ ] **Step 4: Test del comando `help`**

```bash
/workspace/patches/patch-dockerfile-glab.sh help | head -10
```
Expected: l'help mostra `patch-dockerfile-glab.sh -- aggiunge la CLI glab al Dockerfile claudebox` e la lista comandi.

- [ ] **Step 5: Test idempotenza con un Dockerfile fittizio**

```bash
TMPDIR=$(mktemp -d)
echo 'FROM ubuntu:22.04' > "$TMPDIR/Dockerfile"
cd "$TMPDIR"
/workspace/patches/patch-dockerfile-glab.sh patch
/workspace/patches/patch-dockerfile-glab.sh patch  # secondo run: deve essere idempotente
/workspace/patches/patch-dockerfile-glab.sh status
/workspace/patches/patch-dockerfile-glab.sh remove
/workspace/patches/patch-dockerfile-glab.sh status
cd /workspace
rm -rf "$TMPDIR"
```
Expected:
- primo patch: `OK Dockerfile patchato (...): glab v1.49.0.`
- secondo patch: `OK Patch glab gia' presente in Dockerfile. Niente da fare.`
- status dopo patch: `Patch glab applicato : si'  (glab 1.49.0)`
- remove: `OK Blocco patch glab rimosso da Dockerfile.`
- status dopo remove: `Patch glab applicato : no  (./patch-dockerfile-glab.sh patch)`

- [ ] **Step 6: Commit**

```bash
cd /workspace
git add patches/patch-dockerfile-glab.sh
git -c user.email=luca.polignone@youtilitycenter.it -c user.name="Luca Polignone" \
    commit -m "feat(patch): add patch-dockerfile-glab to install GitLab CLI

New optional patch that installs glab v1.49.0 in the container, mirroring
the structure of the existing java/uvx/docker patches: marker-gated,
idempotent, BSD/GNU sed gate, GLAB_VERSION env override, supports amd64
and arm64."
```

---

## Task 8: Patch `patches/patch-dockerfile-glab.ps1`

**Files:**
- Create: `/workspace/patches/patch-dockerfile-glab.ps1`

- [ ] **Step 1: Creare il file**

Usare come modello `/workspace/patches/patch-dockerfile-uvx.ps1`. Scrivere `/workspace/patches/patch-dockerfile-glab.ps1`:

```powershell
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
RUN set -eux; \\
    arch="`$(dpkg --print-architecture)"; \\
    case "`$arch" in \\
        amd64) glab_arch="x86_64" ;; \\
        arm64) glab_arch="arm64" ;; \\
        *) echo "unsupported arch: `$arch" >&2; exit 1 ;; \\
    esac; \\
    curl -fsSL -o /tmp/glab.tgz \\
        "https://gitlab.com/gitlab-org/cli/-/releases/v`${GLAB_VERSION}/downloads/glab_`${GLAB_VERSION}_linux_`${glab_arch}.tar.gz"; \\
    tar -xzf /tmp/glab.tgz -C /tmp; \\
    install -m 0755 /tmp/bin/glab /usr/local/bin/glab; \\
    rm -rf /tmp/glab.tgz /tmp/bin /tmp/LICENSE /tmp/README.md 2>/dev/null || true; \\
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
```

- [ ] **Step 2: Verifica visiva**

```bash
head -30 /workspace/patches/patch-dockerfile-glab.ps1
```
Expected: il file inizia con il blocco `<#  .SYNOPSIS ... #>` e `param([string]$Command = 'patch')`.

- [ ] **Step 3: Commit**

```bash
cd /workspace
git add patches/patch-dockerfile-glab.ps1
git -c user.email=luca.polignone@youtilitycenter.it -c user.name="Luca Polignone" \
    commit -m "feat(patch): add patch-dockerfile-glab.ps1 (PowerShell parity)

PowerShell counterpart of patch-dockerfile-glab.sh. Same commands
(patch/remove/status/help), same marker, same GLAB_VERSION default."
```

---

## Task 9: Documentazione

**Files:**
- Modify: `/workspace/README.md` — nuova sezione "GitLab credentials"
- Modify: `/workspace/CLAUDE.md` — citazione del prompt + della patch

- [ ] **Step 1: Identificare il punto di inserimento nel README**

```bash
grep -n "^## " /workspace/README.md | head -20
```

Decidere se la nuova sezione "GitLab credentials" va dopo la sezione sui profili o dopo la sezione DooD (cercare la sezione più affine). Se entrambe sono presenti, inserire **dopo** quella sui profili.

- [ ] **Step 2: Aggiungere la sezione al README**

Inserire la seguente sezione nel posto identificato allo Step 1:

```markdown
## GitLab credentials

Claudebox può iniettare nel container, opt-in e per-profilo, le credenziali GitLab presenti sull'host:

- la variabile `GITLAB_TOKEN` (se settata nello shell host) viene esposta come env var nel container;
- la dir `~/.config/glab-cli/` (config della CLI [`glab`](https://gitlab.com/gitlab-org/cli)) viene bind-montata read-only e copiata in `/home/node/.config/glab-cli/`.

La scelta sì/no viene chiesta al primo `claudebox init` o `claudebox start` di un profilo, con default `yes`, e salvata in `~/.config/claudebox/<profilo>.conf` (formato `KEY=value`):

```
INJECT_GITLAB_CREDS=yes
```

Per cambiare la scelta successivamente, edita a mano il file:

```bash
echo 'INJECT_GITLAB_CREDS=no' > ~/.config/claudebox/work.conf
```

L'iniezione di credenziali è utile anche **senza** la CLI `glab`: `GITLAB_TOKEN` viene usato da `git` HTTPS con credential helpers, da Maven con un `settings.xml` che referenzia env var, e da script custom.

Per avere anche la CLI `glab` dentro al container, copia la patch dedicata nel progetto:

```bash
cp /percorso/a/claudebox/patches/patch-dockerfile-glab.sh .devcontainer/
chmod +x .devcontainer/patch-dockerfile-glab.sh
claudebox start
```

### Trade-off di sicurezza

- Il token come env var (`-e GITLAB_TOKEN=...`) è visibile a chi può chiamare `docker inspect` sul container. È il modello standard di Docker, accettato dal design.
- La config dir è montata read-only: il container non può modificare lo stato di `glab` sull'host.
- Il file `~/.config/claudebox/<profilo>.conf` contiene solo un flag yes/no, mai il token.
```

- [ ] **Step 3: Aggiornare `CLAUDE.md`**

Localizzare in `/workspace/CLAUDE.md` la sezione "Comandi utente". Modificare la riga per `claudebox init` aggiungendo la menzione del prompt:

Da:
```
- `claudebox init` — scarica Dockerfile + init-firewall.sh ufficiali Anthropic, genera `devcontainer.json`, applica le patch.
```

A:
```
- `claudebox init` — scarica Dockerfile + init-firewall.sh ufficiali Anthropic, genera `devcontainer.json`, **chiede una volta sola se iniettare le credenziali GitLab dell'host** (default sì, persistito in `~/.config/claudebox/<profilo>.conf`), applica le patch.
```

Inoltre, nella sezione "Layout della repo" sotto `patches/`, aggiungere la nuova patch:

Da:
```
patches/                template di patch da copiare nei progetti target
  patch-dockerfile-docker.{sh,ps1}    Docker CLI + buildx + compose (DooD)
  patch-dockerfile-java.{sh,ps1}      Eclipse Temurin 21 + Maven
  patch-dockerfile-uvx.{sh,ps1}       uv + uvx (Astral)
  patch-dockerfile.{sh,ps1}           project-specific (PHP + rete yougo-dev)
```

A:
```
patches/                template di patch da copiare nei progetti target
  patch-dockerfile-docker.{sh,ps1}    Docker CLI + buildx + compose (DooD)
  patch-dockerfile-glab.{sh,ps1}      GitLab CLI 'glab'
  patch-dockerfile-java.{sh,ps1}      Eclipse Temurin 21 + Maven
  patch-dockerfile-uvx.{sh,ps1}       uv + uvx (Astral)
  patch-dockerfile.{sh,ps1}           project-specific (PHP + rete yougo-dev)
```

Aggiungere infine, in coda a `CLAUDE.md` (prima dell'ultima sezione "Cose da non fare" oppure dopo la sezione "Docker-outside-of-Docker (DooD)"), un nuovo paragrafo:

```markdown
## GitLab credentials injection

`cmd_up` legge `~/.config/claudebox/<profilo>.conf` (chiave `INJECT_GITLAB_CREDS`). Se `yes`, aggiunge al `docker run`:

- `-v "$HOME/.config/glab-cli:/host-glab-cli:ro"` (se la dir esiste sull'host);
- `-e GITLAB_TOKEN` (se l'env var è set sull'host).

Il `postStartCommand` in `devcontainer.json` copia `/host-glab-cli/` in `/home/node/.config/glab-cli/`. Un safety-net `docker exec` in `cmd_up` ripete la copia per chi ha fatto `init` prima di questa feature.

Il prompt avviene in `cmd_init` (prima di `run_dockerfile_patches`) e in `cmd_start` (subito dopo il prompt "Update?"). Default: `yes`. In non-TTY o con `-y`, viene salvato il default senza chiedere.
```

- [ ] **Step 4: Verifica visiva**

```bash
git diff README.md CLAUDE.md | wc -l
```
Expected: alcune decine di linee diff (le sezioni aggiunte).

- [ ] **Step 5: Commit**

```bash
cd /workspace
git add README.md CLAUDE.md
git -c user.email=luca.polignone@youtilitycenter.it -c user.name="Luca Polignone" \
    commit -m "docs: document GitLab credentials injection and glab patch

README: new 'GitLab credentials' section explaining the opt-in prompt,
the conf file format and location, the security trade-offs, and the
companion patch. CLAUDE.md: extend the cmd_init bullet, add the new
patch to the repo layout, and add an 'GitLab credentials injection'
implementation note."
```

---

## Verifica finale (manuale, post-implementazione)

Dopo il completamento di tutti i task, l'utente esegue queste verifiche end-to-end. Non sono task del piano (richiedono interazione con Docker reale) ma sono il "test plan" della spec.

1. **Fresh profilo, prompt default sì, GITLAB_TOKEN set**:
   ```bash
   rm -f ~/.config/claudebox/personal.conf
   export GITLAB_TOKEN=test123
   cd ~/some-test-project
   /workspace/claudebox.sh init   # rispondere Enter al prompt GitLab
   grep INJECT_GITLAB_CREDS ~/.config/claudebox/personal.conf
   ```
   Expected: `INJECT_GITLAB_CREDS=yes` nel file.

2. **`cmd_up` aggiunge l'env var**:
   ```bash
   /workspace/claudebox.sh up
   docker inspect "$(docker ps -q --filter name=claudebox-)" | grep -A2 '"Env"' | grep GITLAB_TOKEN
   ```
   Expected: una riga `"GITLAB_TOKEN=test123"`.

3. **Risposta `n` al prompt**:
   ```bash
   rm -f ~/.config/claudebox/personal.conf
   /workspace/claudebox.sh init   # rispondere n al prompt GitLab
   grep INJECT_GITLAB_CREDS ~/.config/claudebox/personal.conf
   ```
   Expected: `INJECT_GITLAB_CREDS=no`.

4. **Flag `-y` su fresh profile (default)**:
   ```bash
   rm -f ~/.config/claudebox/work.conf
   /workspace/claudebox.sh -p work start  # con -y in script: nessun prompt
   ```
   Expected: nessun prompt, `INJECT_GITLAB_CREDS=yes` persistito.

5. **Profili indipendenti**:
   - `personal` con `yes` e `work` con `no` → due file conf indipendenti, `docker inspect` mostra l'env var solo nel container personal.

6. **Patch `glab`**:
   ```bash
   cp /workspace/patches/patch-dockerfile-glab.sh ~/some-test-project/.devcontainer/
   chmod +x ~/some-test-project/.devcontainer/patch-dockerfile-glab.sh
   /workspace/claudebox.sh up
   docker exec "$(docker ps -q --filter name=claudebox-)" glab --version
   ```
   Expected: `glab version 1.49.0`.

7. **PowerShell parity** (su Windows): ripetere step 1, 3 e 4.

---

## Self-review

**Spec coverage**:
- ✅ Profile config file (helpers): Task 1 (sh), Task 2 (ps1).
- ✅ Prompt + wiring init/start: Task 3 (sh), Task 4 (ps1).
- ✅ cmd_up docker opts: Task 5 (sh), Task 6 (ps1).
- ✅ postStartCommand extension: Task 5 (sh), Task 6 (ps1).
- ✅ Safety-net docker exec: Task 5 (sh), Task 6 (ps1).
- ✅ Patch glab: Task 7 (sh), Task 8 (ps1).
- ✅ Documentazione: Task 9.
- ✅ Manual verification del test plan della spec: sezione "Verifica finale".

**Placeholder scan**: nessun TBD, nessun "implement later", nessun "add appropriate error handling". I blocchi di codice sono completi e copia-incollabili. Le linee di codice da modificare sono identificate con il numero di riga corrente.

**Type consistency**:
- nome funzioni bash coerente in tutti i task (`profile_conf_path`, `profile_conf_get`, `profile_conf_set`, `ensure_gitlab_creds_choice`);
- nome funzioni PowerShell coerente (`Get-ProfileConfPath`, `Get-ProfileConfValue`, `Set-ProfileConfValue`, `Ensure-GitlabCredsChoice`);
- chiave conf: `INJECT_GITLAB_CREDS` in tutti i task;
- marker patch: `CLAUDEBOX_PATCH_GLAB_BEGIN/END` in tutti i task;
- target mount: `/host-glab-cli` (RO) → `/home/node/.config/glab-cli/` (RW) in tutti i task;
- versione glab default `1.49.0` in tutti i task.
