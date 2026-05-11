# GitLab credentials injection in claudebox

**Status**: design approved, pending implementation plan
**Date**: 2026-05-11
**Author**: Luca Polignone (with Claude)

## Sommario

Aggiungere a `claudebox` (sia `claudebox.sh` sia `claudebox.ps1`) la possibilità — opzionale, per-profilo, persistente — di iniettare nel container le credenziali GitLab dell'host. L'iniezione consiste in:

- bind mount **read-only** di `~/.config/glab-cli/` (config CLI `glab`);
- pass-through dell'env var `GITLAB_TOKEN`.

La scelta sì/no è chiesta interattivamente al primo `init`/`start` di un profilo, con default `yes`, e salvata in `~/.config/claudebox/<profilo>.conf`.

In parallelo viene aggiunta una nuova patch ufficiale `patches/patch-dockerfile-glab.{sh,ps1}` che installa il binario `glab` nel container, opt-in con lo stesso pattern delle altre patch (`java`, `uvx`, `docker`).

I due artefatti sono **indipendenti**: l'iniezione delle credenziali è utile anche senza la CLI `glab` (`GITLAB_TOKEN` serve a `git` HTTPS, Maven, script custom).

## Contesto

Oggi `claudebox.sh:544-550` (e l'equivalente PowerShell) monta nel container:

- workspace del progetto;
- `~/.claude*` (host config Claude) come read-only + volume condiviso per profilo;
- `~/.claude/plugins` come read-only;
- `~/.config/ccstatusline` come read-only + volume condiviso.

Nessuna credenziale GitLab è esposta. Per progetti che hanno bisogno di interagire con GitLab da dentro al container (ad esempio `glab mr create`, push HTTPS autenticato, fetch da package registry privato) bisogna oggi inserire manualmente il token a runtime.

Il pattern già consolidato per estendere il `docker run` con opzioni condizionali è la **marker-detection** del Dockerfile: il blocco DooD in `claudebox.sh:510-585` aggiunge `-v /var/run/docker.sock` solo se il marker `CLAUDEBOX_PATCH_DOCKER_BEGIN` è presente. Questo pattern non è però la scelta giusta qui, perché la preferenza è **per-profilo** (l'utente vuole poter dire "su `work` sì, su `personal` no" senza dover toccare il `Dockerfile` di ogni progetto).

## Obiettivi

- Permettere all'utente di scegliere se iniettare le credenziali GitLab, in modo **persistente per profilo**, con prompt interattivo e default sì.
- Non rompere progetti esistenti (l'utente che ignora la feature deve continuare a funzionare come prima).
- Mantenere parità funzionale tra `claudebox.sh` e `claudebox.ps1`.
- Mantenere portabilità (`bash 3.2` su macOS, BSD vs GNU `sed`).
- Mantenere il modello di sicurezza esistente: nessun token in immagine, mount RO, nessun logging del token.

## Non obiettivi (esplicito YAGNI)

- Sub-comando `claudebox config gitlab on/off`: non in v1. Per cambiare la scelta l'utente edita il file `.conf` a mano (documentato).
- Storage del token in keychain / secret manager.
- Iniezione di `~/.m2/settings.xml` o SSH key per GitLab (esclusi esplicitamente in brainstorming).
- Auto-install della patch `glab` da `claudebox` (la patch resta opt-in copiata nel progetto come `java`/`uvx`/`docker`).
- Riprompt automatico al cambio di versione di `claudebox`.

## Architettura

La feature si compone di due artefatti separati ma complementari.

### (A) Iniezione credenziali — modifica al core di `claudebox`

#### File di config per-profilo

**Path**: `~/.config/claudebox/<profilo>.conf` — un file per profilo (`personal.conf`, `work.conf`, …).

**Formato**: `KEY=value` shell-sourceable, una chiave per riga, niente commenti, niente apici.

```
INJECT_GITLAB_CREDS=yes
```

**Perché qui e non in `~/.claude-<profilo>/`**: separa lo state di claudebox da quello di Claude Code, ed evita che la conf venga esposta nel container via il bind mount `/host-claude`.

La directory `~/.config/claudebox/` viene creata lazy alla prima scrittura (`mkdir -p`).

#### Helper functions (bash)

In `claudebox.sh`, vicino a `volume_suffix()`:

- `profile_conf_path [profilo]` — stampa il path del file conf per il profilo dato (default: `$PROFILE`).
- `profile_conf_get KEY [DEFAULT]` — stampa il value della chiave, oppure il default se mancante. Implementazione: `grep -E "^${KEY}=" "$conf" | head -1 | cut -d= -f2-`. Senza associative array (compat bash 3.2).
- `profile_conf_set KEY VALUE` — crea dir e file se mancanti; se la chiave esiste, la sostituisce con `sed -i` (gate GNU vs BSD identico a `patches/patch-dockerfile.sh:remove`); altrimenti appende.

#### Helper functions (PowerShell, parità)

In `claudebox.ps1`:

- `Get-ProfileConfPath [-Prof <string>]`
- `Get-ProfileConfValue [-Key <string>] [-Default <string>]`
- `Set-ProfileConfValue [-Key <string>] [-Value <string>]`

Implementazione con `Get-Content` / `Set-Content` UTF-8 senza BOM, regex `^Key=`.

#### Prompt interattivo

Funzione `ensure_gitlab_creds_choice` chiamata da `cmd_init` e `cmd_start`:

```bash
ensure_gitlab_creds_choice() {
    local current
    current=$(profile_conf_get INJECT_GITLAB_CREDS)
    if [ -n "$current" ]; then
        return 0  # già configurato
    fi

    # In non-tty (pipe / CI), salva default senza prompt
    if [ ! -t 0 ]; then
        profile_conf_set INJECT_GITLAB_CREDS yes
        return 0
    fi

    # read_input_or_default rispetta già $AUTO_YES (claudebox.sh:53):
    # con -y restituisce il default senza chiedere.
    local answer
    answer=$(read_input_or_default \
        "  Inject host GitLab credentials (\$GITLAB_TOKEN + ~/.config/glab-cli) into the container? [Y/n]: " \
        "yes")
    case "$(echo "$answer" | tr '[:upper:]' '[:lower:]')" in
        n|no) profile_conf_set INJECT_GITLAB_CREDS no ;;
        *)    profile_conf_set INJECT_GITLAB_CREDS yes ;;
    esac
}
```

Note:
- `read_input_or_default` esiste già nel codice (vedi `cmd_init` per la richiesta del Claude config path) e gestisce internamente il flag `$AUTO_YES`: con `-y` restituisce il default senza prompt.
- `[ ! -t 0 ]` fallback su pipe / CI: usa default senza bloccare.
- `tr '[:upper:]' '[:lower:]'` per compat bash 3.2 (no `${var,,}`).
- `AUTO_YES` è la variabile reale del codebase (`claudebox.sh:23`, bool `true`/`false`), non un intero.

**Dove viene chiamata**:

- `cmd_init` — dopo che `Dockerfile` e `devcontainer.json` sono stati scritti, **prima** della chiamata a `run_dockerfile_patches` finale. Primo onboarding.
- `cmd_start` — subito dopo il prompt esistente "do you want to update?". Se l'utente è arrivato direttamente a `start` senza `init`, il prompt c'è. Se la conf esiste già, nessun prompt.
- `cmd_up` — **non** chiama `ensure_gitlab_creds_choice`. `cmd_up` deve restare non-bloccante. Legge soltanto la conf con default `no` se mancante.

#### Costruzione dei docker opts in `cmd_up`

Dopo il blocco DooD (`claudebox.sh:510-585`), aggiungere:

```bash
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
        info "GitLab credentials injected (glab-cli config: $([ "$has_dir" = "1" ] && echo yes || echo no), GITLAB_TOKEN env: $([ "$has_token" = "1" ] && echo yes || echo no))"
    else
        warn "INJECT_GITLAB_CREDS=yes but neither \$GITLAB_TOKEN nor ~/.config/glab-cli/ available on host — skipping"
    fi
fi
```

#### Copia nel container

Mount RO + copia in dir scrivibile, simmetrico al pattern `/host-claude` esistente. Due punti di integrazione:

1. **`devcontainer.json` (generato da `cmd_init`)** — estendere `postStartCommand` con:
   ```sh
   mkdir -p /home/node/.config/glab-cli && \
   if [ -d /host-glab-cli ]; then cp -rn /host-glab-cli/. /home/node/.config/glab-cli/ 2>/dev/null || true; fi
   ```
   Il blocco è tollerante: se `/host-glab-cli` non è montato (utente con `INJECT_GITLAB_CREDS=no`), il check `-d` salta tutto.

2. **Safety-net in `cmd_up`** — per utenti che hanno fatto `init` prima di questa feature e quindi hanno un `devcontainer.json` privo della copia. Subito dopo `docker exec ... init-firewall.sh`, nello stesso blocco "post-start fixups" che già ospita il `chgrp docker` per DooD:

```bash
if [ "$inject_glab" = "yes" ]; then
    docker exec -u node "$cname" bash -c \
        'mkdir -p /home/node/.config/glab-cli && \
         if [ -d /host-glab-cli ]; then cp -rn /host-glab-cli/. /home/node/.config/glab-cli/ 2>/dev/null || true; fi' \
        >/dev/null 2>&1 || true
fi
```

`cp -rn` (no-clobber) garantisce idempotenza: modifiche fatte dentro al container in sessioni precedenti non vengono soprascritte.

#### Parità PowerShell

Stessa logica in `claudebox.ps1`:

- `Ensure-GitlabCredsChoice` chiamata in `cmd_init` e `cmd_start`.
- Nel `docker run` di `cmd_up`, costruzione condizionale di `$dockerArgs` con `-v` e `-e`.
- Safety-net `docker exec` analoga.

### (B) Patch installativa `patches/patch-dockerfile-glab.{sh,ps1}`

Segue il pattern delle altre patch ufficiali. Modello più vicino: `patches/patch-dockerfile-uvx.sh` (installa un singolo binario).

**Marker**: `# >>> CLAUDEBOX_PATCH_GLAB_BEGIN >>>` / `# <<< CLAUDEBOX_PATCH_GLAB_END <<<`

**Env override**: `GLAB_VERSION` (default: `1.49.0`, da verificare/aggiornare a tempo di implementazione contro l'ultima release stabile su https://gitlab.com/gitlab-org/cli/-/releases).

**Comandi supportati**: `patch` (default), `remove`, `status`, `help`.

**Blocco inserito nel Dockerfile** (prima dello `USER node` finale, come per le altre patch):

```dockerfile
# >>> CLAUDEBOX_PATCH_GLAB_BEGIN >>>
ARG GLAB_VERSION=1.49.0
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
        amd64) glab_arch="x86_64" ;; \
        arm64) glab_arch="arm64" ;; \
        *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/glab.tgz \
        "https://gitlab.com/gitlab-org/cli/-/releases/v${GLAB_VERSION}/downloads/glab_${GLAB_VERSION}_linux_${glab_arch}.tar.gz"; \
    tar -xzf /tmp/glab.tgz -C /tmp; \
    install -m 0755 /tmp/bin/glab /usr/local/bin/glab; \
    rm -rf /tmp/glab.tgz /tmp/bin /tmp/LICENSE /tmp/README.md 2>/dev/null || true; \
    glab --version
# <<< CLAUDEBOX_PATCH_GLAB_END <<<
```

Note:
- `find_dockerfile()` identica alle altre patch (override `$DOCKERFILE`, fallback `Dockerfile`, `.devcontainer/Dockerfile`).
- Backup `${DOCKERFILE}.orig` se non esiste (convenzione esistente).
- Su `remove`: cancella il blocco tra i marker con il gate GNU/BSD `sed`.
- Tab-completion: **fuori scope v1** (`glab` funziona senza, container effimero).

La versione `.ps1` è traduzione 1:1 con `Get-Content` / regex / `Set-Content` come per le altre patch.

## Edge case ed error handling

| Caso | Comportamento |
|---|---|
| `INJECT_GITLAB_CREDS=yes` ma niente `$GITLAB_TOKEN` né `~/.config/glab-cli` | `warn`, container parte normalmente. |
| `~/.config/glab-cli` esiste ma vuota | Mount fatto, `cp -rn` no-op, non rompe nulla. |
| Conf file presente ma corrotto (riga senza `=`) | `profile_conf_get` ritorna default; silenzioso. |
| `~/.config/claudebox/` non scrivibile (raro) | `profile_conf_set` emette `warn` e continua senza persistere; il prompt ricomparirà al prossimo run. |
| Utente in pipe / CI (`[ ! -t 0 ]`) e conf assente | Default `yes` salvato senza prompt; idem con `-y`. |
| Utente vuole cambiare la scelta dopo | Edit manuale del file `.conf` (documentato in README e `claudebox help`). |
| Token nei log di claudebox? | No: `info` mostra solo "yes/no", mai il valore. Niente `set -x` nel blocco di iniezione. |
| Token visibile a `docker inspect` (env var) | Sì, trade-off accettato del modello `-e VAR=VAL` di Docker. Documentato in README. |
| Patch `glab` non installata nel container | Nessun conflitto: env var e config dir sono valide indipendentemente dal binario. |

## Sicurezza

- Nessun token in immagine (no `ARG`/`ENV` nel Dockerfile per il token).
- Mount RO della config glab → il container non può modificare lo stato glab dell'host.
- File `~/.config/claudebox/<profilo>.conf` contiene solo flag yes/no, mai token: permessi default OK.
- `cp -rn` nel postStart: se l'utente ha modificato `/home/node/.config/glab-cli/` dentro al container in una sessione precedente, le modifiche locali non vengono sovrascritte al riavvio dal mount RO.

## Compatibilità e migrazione

- Utenti esistenti con `.devcontainer/` già generato da una versione precedente di claudebox: il loro `devcontainer.json` **non** ha la riga di copia `cp -rn /host-glab-cli/...`. La safety-net `docker exec` in `cmd_up` copre questo caso senza forzare `claudebox update`. Un eventuale `claudebox update` o `claudebox init` rigenera il `devcontainer.json` con la nuova `postStartCommand`.
- Profili esistenti: nessun file `~/.config/claudebox/<profilo>.conf` → prompt al primo `start` successivo all'upgrade. Default `yes` ⇒ comportamento utile out-of-the-box per chi ha `GITLAB_TOKEN` o `~/.config/glab-cli` sull'host; comportamento neutro (warning, niente di rotto) per chi non ne ha.

## Documentazione

- `README.md`: nuova sezione "GitLab credentials" che spiega il prompt, dove vive la conf, come cambiarla, e la patch opzionale `glab`.
- `CLAUDE.md`: una riga in "Comandi utente" che cita il prompt in `init`/`start`; una nota in "Convenzioni patch" per la nuova patch.
- `claudebox help`: una riga di spiegazione del prompt e del file conf.

## Test plan (manuale)

Non c'è una test suite automatica in repo. Verifiche manuali prima di rilasciare:

1. **Fresh init, profilo `personal`, GITLAB_TOKEN settato**: `claudebox init` chiede, accetto default → conf creata con `yes`. `claudebox up` mostra "GitLab credentials injected (… GITLAB_TOKEN env: yes)". Dentro al container `echo $GITLAB_TOKEN` ritorna il valore.
2. **Fresh init, profilo `work`, dir `~/.config/glab-cli` presente, nessun token**: `claudebox up` monta la dir. Dentro al container `cat /home/node/.config/glab-cli/config.yml` mostra il config (copia, non bind).
3. **Risposta `n` al prompt**: conf `no`. `claudebox up` non aggiunge `-v` né `-e`. `docker inspect` lo conferma.
4. **`claudebox up` dopo `init` vecchio (devcontainer.json privo della postStart estesa)**: la safety-net `docker exec` esegue la copia. Verificare con `docker exec ls /home/node/.config/glab-cli/`.
5. **Flag `-y` su fresh profile**: nessun prompt, conf creata con `yes`.
6. **Profili separati**: `personal` con `yes` e `work` con `no` → due file conf indipendenti, behavior corretto.
7. **Patch `glab`**: applicata, build immagine, `docker exec ... glab --version` ritorna `1.49.0`.
8. **Patch `glab` su entrambe le architetture** (amd64, arm64) se possibile.
9. **PowerShell parity**: ripetere 1, 3, 5 su Windows.

## Open questions

Nessuna al momento del freeze del design. Eventuali aggiustamenti emergeranno durante il plan implementativo e l'esecuzione.
