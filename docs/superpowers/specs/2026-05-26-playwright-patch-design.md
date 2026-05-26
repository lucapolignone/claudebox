# Playwright patch per claudebox

**Status**: design approved, pending implementation plan
**Date**: 2026-05-26
**Author**: Luca Polignone (with Claude)

## Sommario

Aggiungere una nuova patch ufficiale `patches/patch-dockerfile-playwright.{sh,ps1}` che installa nel container devcontainer di claudebox:

- la CLI `@playwright/test` via `npm install -g`, versione pinnabile via env (`PLAYWRIGHT_VERSION`, default `latest`);
- tutti e tre i browser ufficiali (chromium, firefox, webkit) in cache system-wide;
- le dipendenze apt di sistema richieste dai browser (`libnss3`, `libgbm`, fonts, ecc.) tramite `npx playwright install --with-deps`.

La patch segue lo stesso pattern delle altre (`uvx`, `java`, `docker`, `glab`): opt-in copiando il file nella directory `.devcontainer/` del progetto target, idempotente via marker, comandi `patch|remove|status|help`.

## Contesto

Il devcontainer ufficiale di Anthropic (`anthropics/claude-code`) include Node.js ma non ha browser headless né le runtime dependencies necessarie per test E2E. Lavorare su progetti con test Playwright dentro a claudebox richiede oggi un setup manuale ripetitivo (apt deps + npm install + browser download).

L'esistente meccanismo di discovery patch in `claudebox.sh:159-200` itera `patch-dockerfile*.{sh,ps1}` in ordine alfabetico, eseguendo ciascuna in subshell con `cd` nella directory in cui è stata trovata (`.devcontainer/` o project root). Le patch sono idempotenti grazie ai marker `CLAUDEBOX_PATCH_<NAME>_BEGIN/END`.

Una patch Playwright si inserisce naturalmente in questo pattern.

## Obiettivi

- Patch idempotente, opt-in, identica in comportamento alle altre patch del repo.
- Versione di `@playwright/test` pinnabile (`PLAYWRIGHT_VERSION` env var, default `latest`), allineata a `UV_VERSION`/`MAVEN_VERSION`/`DOCKER_CHANNEL`.
- Browser scaricati a build-time (tutti e tre), così il container è pronto offline.
- Cache browser system-wide via `PLAYWRIGHT_BROWSERS_PATH=/ms-playwright` — un solo download condiviso fra `root` e `node`.
- Parità funzionale `.sh` ↔ `.ps1`.
- Portabilità `bash 3.2` (macOS), GNU vs BSD `sed`.

## Non obiettivi (esplicito YAGNI)

- Variante Python (`pip install playwright` / `uvx playwright`): fuori scope, l'utente ha scelto Node.
- Auto-install della patch da `claudebox init`: resta opt-in copiata manualmente come tutte le altre.
- Sub-comando `claudebox playwright`: non serve, lo script-patch fa già `patch|remove|status`.
- Selezione granulare dei browser (solo chromium / solo firefox): se serve in futuro, env var aggiuntiva. v1 = tutti.
- Caching delle build apt (apt cache mount): il devcontainer è ricostruito raramente, complica la patch senza payoff.

## Architettura

### Posizionamento

- `/workspace/patches/patch-dockerfile-playwright.sh` (macOS/Linux)
- `/workspace/patches/patch-dockerfile-playwright.ps1` (Windows)

Entrambi sono **template**: la repo claudebox non li esegue mai sui propri file. L'utente li copia in `.devcontainer/` del progetto target; `claudebox init|update|up` li scopre e li esegue (vedi `claudebox.sh:159-200`).

### Blocco Dockerfile generato

La patch appende al `Dockerfile` del progetto target il seguente blocco (tra marker):

```dockerfile
# >>> CLAUDEBOX_PATCH_PLAYWRIGHT_BEGIN >>>
# Playwright v${PLAYWRIGHT_VERSION} (Node) + tutti i browser + apt deps
# Aggiunto da patch-dockerfile-playwright.sh -- riapplicato automaticamente da claudebox.

USER root

# Cache browser system-wide: un solo download condiviso fra utenti.
# Convenzione ufficiale Playwright per Docker.
ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright

# 1. CLI @playwright/test globale
RUN npm install -g @playwright/test@${PLAYWRIGHT_VERSION}

# 2. Browser (chromium+firefox+webkit, default senza argomenti) + apt deps
RUN npx playwright install --with-deps

# 3. Permessi RO per utente non-root
RUN chmod -R a+rx /ms-playwright

# 4. Smoke test: fallisce la build se l'install e' rotto
RUN npx playwright --version

USER node
# <<< CLAUDEBOX_PATCH_PLAYWRIGHT_END <<<
```

### Comandi della patch

Identico a `patch-dockerfile-uvx.sh`:

| comando | comportamento |
|---|---|
| `patch` (default) | Appende il blocco se non già presente. Idempotente. Backup `${DOCKERFILE}.orig` una tantum. |
| `remove` | Rimuove il blocco fra marker via `sed -i` (GNU) o `sed -i ''` (BSD). |
| `status` | Mostra se il Dockerfile esiste, se la patch è applicata, versione installata, presenza backup. |
| `help` | Usage. |

### Discovery del Dockerfile

Funzione `find_dockerfile()` che prova in ordine: `${DOCKERFILE:-}` (override env) → `Dockerfile` (cwd, caso `.devcontainer/`) → `.devcontainer/Dockerfile` (cwd = project root).

### Variabili di ambiente

| nome | default | scopo |
|---|---|---|
| `PLAYWRIGHT_VERSION` | `latest` | Versione di `@playwright/test` (es. `1.49.0`). Per build riproducibile, pinnare. |
| `DOCKERFILE` | (auto) | Override del Dockerfile target. |

## Implementazione

- Lo script `.sh` è una **copia diretta** di `patch-dockerfile-uvx.sh` con:
  - `MARKER_*` → `CLAUDEBOX_PATCH_PLAYWRIGHT_*`
  - `UV_VERSION` → `PLAYWRIGHT_VERSION`
  - Header docstring aggiornato (uvx → playwright, install via `COPY` distroless → `npm install -g` + `npx playwright install --with-deps`)
  - `cmd_patch` heredoc col blocco Dockerfile sopra
  - `cmd_status` estrae versione cercando `playwright/test@<ver>` invece di `astral-sh/uv:<ver>`
  - `cmd_help` aggiornato (browsers, env var, dimensione ~700MB)
- Lo script `.ps1` è una copia di `patch-dockerfile-uvx.ps1` con gli stessi rename.
- Tutti i commenti tecnici già presenti nel template (`-euo pipefail`, BSD vs GNU `sed`, fallback compatibili) rimangono.

## Trade-off

- **Dimensione immagine** (+~700 MB): scelta deliberata — l'utente ha chiesto tutti e tre i browser a build-time. L'alternativa (browser deferred a runtime) salva spazio ma rompe l'uso offline. Documentato nel commento del Dockerfile e nell'help.
- **Build-time apt update**: `npx playwright install --with-deps` esegue `apt-get update` + install dei pacchetti. Aggiunge ~30 s alla prima build. Le build successive sono cached da Docker layer cache (l'intero RUN è cached finché `PLAYWRIGHT_VERSION` non cambia).
- **`PLAYWRIGHT_VERSION=latest`** dà build non riproducibili. Documentato nell'help come trade-off scelto a favore della comodità. Pinning consigliato per CI.

## Sicurezza

- Nessuna credenziale toccata.
- L'install gira come `USER root` solo il tempo necessario, poi `USER node`.
- I browser sono installati in `/ms-playwright` (fuori dalla home dell'utente), montati read-execute per tutti.

## Documentazione

- Aggiornare `README.md` aggiungendo la nuova patch nella lista delle patch ufficiali (sezione esistente accanto a `uvx`/`java`/`glab`/`docker`).
- Il `CLAUDE.md` di claudebox elenca le patch in `patches/`: aggiungere la riga `patch-dockerfile-playwright.{sh,ps1}    Playwright + browser headless + apt deps`.

## Verifica manuale (non obiettivi automated test — il repo non ha test suite)

1. `cp patches/patch-dockerfile-playwright.sh /tmp/project/.devcontainer/`
2. `cd /tmp/project && claudebox init` (o `claudebox update` se già inizializzato).
3. Grep nel Dockerfile generato: `grep CLAUDEBOX_PATCH_PLAYWRIGHT_BEGIN .devcontainer/Dockerfile`.
4. `claudebox up`, poi dentro al container: `npx playwright --version`, `ls /ms-playwright/`.
5. Eseguire un test E2E reale (es. `npx playwright test` su un progetto Playwright).
6. `./patch-dockerfile-playwright.sh remove` → verificare blocco rimosso dal Dockerfile.
7. Idempotenza: eseguire `patch` due volte → secondo run dice "già presente".
