# Claudebox — guida per Claude Code

## Cos'è il progetto

`claudebox` è un wrapper attorno al devcontainer ufficiale di Anthropic per Claude Code. Fa partire un container isolato per il progetto corrente, con il Dockerfile scaricato da `anthropics/claude-code` più patch custom riapplicate automaticamente.

Niente backend, niente test. Tutto vive in due script gemelli:

- `claudebox.sh` — macOS/Linux
- `claudebox.ps1` — Windows

I due script devono restare allineati: ogni feature/fix che tocca uno dei due va replicato sull'altro. La review delle PR controlla il diff di entrambi.

## Layout della repo

```
claudebox.sh / .ps1     entry point (install + comandi: init/up/start/update/...)
patches/                template di patch da copiare nei progetti target
  patch-dockerfile-docker.{sh,ps1}    Docker CLI + buildx + compose (DooD)
  patch-dockerfile-java.{sh,ps1}      Eclipse Temurin 21 + Maven
  patch-dockerfile-uvx.{sh,ps1}       uv + uvx (Astral)
  patch-dockerfile.{sh,ps1}           project-specific (PHP + rete yougo-dev)
README.md               documentazione utente
.devcontainer/          GENERATO da `claudebox init` nei progetti target — gitignored qui
```

I file in `patches/` non sono mai eseguiti da questa repo: sono template. Lo script `claudebox.sh` cerca patch dentro al progetto utente (`.devcontainer/` o project root del progetto), non in `patches/` di questa repo.

## Discovery delle patch (importante)

Vedi `claudebox.sh:159-200` (`run_dockerfile_patches`) e `claudebox.ps1` per la versione PowerShell.

- Il pattern è `patch-dockerfile*.sh` (rispettivamente `*.ps1`).
- Cerca in due posizioni del progetto utente, in ordine: `.devcontainer/` poi project root.
- I file matching vengono iterati in ordine alfabetico (`find ... | sort`).
- Ogni patch viene eseguita in subshell con `cd` dentro la directory in cui è stata trovata; quindi:
  - Patch in `.devcontainer/` → cwd = `.devcontainer/` → la patch usa `DOCKERFILE="Dockerfile"` (relativo).
  - Patch in project root → cwd = project root → la patch usa `DOCKERFILE=".devcontainer/Dockerfile"`.
- L'esecuzione è invocata da tre punti: fine `cmd_init`, fine `cmd_update`, inizio `cmd_up` (safety net).
- Le patch DEVONO essere idempotenti — convenzione: marker `# >>> CLAUDEBOX_PATCH_<NAME>_BEGIN >>>` / `# <<< CLAUDEBOX_PATCH_<NAME>_END <<<` e early-return se il marker è già presente.

Se la build di un'immagine non include una patch presunta applicata, il primo sospetto è una versione installata stantia di `claudebox` (`~/.local/bin/claudebox`) — la funzione di discovery è stata rimossa per errore in `380bb70` e ripristinata in `8a69780`. Verifica con: `grep -c run_dockerfile_patches "$(command -v claudebox)"`. Se `0`, ri-installa con `bash claudebox.sh install`.

## Convenzioni patch

Per scrivere/modificare una patch in `patches/`:

1. Shebang `#!/usr/bin/env bash` + `set -euo pipefail`.
2. Marker univoci (`MARKER_BEGIN` / `MARKER_END`) — nome distintivo, no collisioni con altre patch.
3. Funzione `find_dockerfile()` che prova in ordine: `${DOCKERFILE:-}` (override), `Dockerfile`, `.devcontainer/Dockerfile`.
4. Comandi standard supportati: `patch` (default, idempotente), `remove`, `status`, `help`.
5. Su `patch`, fai backup `cp "$DOCKERFILE" "${DOCKERFILE}.orig"` solo se non esiste già.
6. Su `remove`, usa `sed -i` GNU vs `sed -i ''` BSD (rileva con `sed --version 2>/dev/null | grep -q GNU`).
7. Override versione via env var (es. `MAVEN_VERSION`, `UV_VERSION`, `DOCKER_CHANNEL`).

Tutte le patch esistenti seguono questo pattern — usalo come riferimento.

## Portabilità (importante)

Lo script `claudebox.sh` deve funzionare su **macOS bash 3.2** (default di sistema). Quindi:

- NIENTE `${var,,}` (richiede bash 4+) — usa `tr '[:upper:]' '[:lower:]'`.
- NIENTE `mapfile` / `readarray` — usa `while IFS= read -r ... done < <(...)`.
- NIENTE `realpath` standalone — c'è `_resolve_path` come fallback portabile.
- BSD `find` non supporta `-printf`; BSD `sed -i` richiede argomento dopo `-i`.
- BSD `stat` usa `-f '%g'`, GNU `stat` usa `-c '%g'` — sempre fallback `||`.

Esempi di fix portabili sono già nel codice marcati con `# FIX:` — leggi i commenti prima di modificare.

## Comandi utente (cosa fa cosa)

- `claudebox install` — copia lo script in `~/.local/bin` (o `~/bin`) e aggiunge al `PATH`.
- `claudebox init` — scarica Dockerfile + init-firewall.sh ufficiali Anthropic, genera `devcontainer.json`, applica le patch.
- `claudebox update` — ri-scarica Dockerfile + init-firewall.sh (devcontainer.json invariato), riapplica le patch.
- `claudebox up` — applica patch (safety net), pinna versione `@anthropic-ai/claude-code` da npm, builda immagine, fa partire container con bind mount appropriati, inizializza firewall, lancia `claude --dangerously-skip-permissions`.
- `claudebox start` — chiede se aggiornare (default no), poi `init` (se serve) o `update` (se richiesto), poi `up`. Flag `-y` salta tutti i prompt.
- `claudebox shell` / `stop` / `destroy` — operazioni standard sul container.

## Profili

`-p <nome>` separa CLAUDE_CONFIG_DIR e volume condiviso per profilo (`personal` default; `work` → `~/.claude-work`; ecc.). Il container name include il profilo (tranne `personal`, per retrocompatibilità).

## Docker-outside-of-Docker (DooD)

Se `.devcontainer/Dockerfile` contiene il marker `CLAUDEBOX_PATCH_DOCKER_BEGIN`, `cmd_up` aggiunge automaticamente:

- `-v /var/run/docker.sock:/var/run/docker.sock`
- `--group-add <gid>` con il GID del docker.sock host
- post-firewall: `chgrp docker /var/run/docker.sock && chmod 660` dentro al container, per allineare il bind mount.

Vedi `claudebox.sh:510-585`. Su Docker Desktop il GID alignment non serve (socket world-rw), ma il `--group-add` è innocuo.

## Convenzioni di commit

Conventional Commits (`feat:`, `fix:`, `chore:`, `refactor:`, `docs:`).

## Cose da non fare

- Non aggiungere logica di runtime in `patches/*.sh` che venga eseguita dalla repo claudebox stessa — restano template.
- Non cambiare il pattern di discovery (`patch-dockerfile*.sh`) senza aggiornare README + entrambi gli script (sh + ps1).
- Non rimuovere il safety net in `cmd_up` (chiamata a `run_dockerfile_patches`): è il motivo per cui aggiungere una patch dopo `init` funziona senza ri-init.
- Non assumere bash ≥4 nei file shell.
- Non committare `.devcontainer/` di questa repo (è gitignored): è generato per testare manualmente, non è artefatto del progetto.
