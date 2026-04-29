# claudebox

Devcontainer isolato per [Claude Code](https://github.com/anthropics/claude-code), con un sistema di **patch del Dockerfile componibili** che sopravvivono agli aggiornamenti del file ufficiale Anthropic.

Questa repo contiene lo script `claudebox` (sh + ps1) e i patch project-specific per portare nel devcontainer Java 21, Maven, PHP 8, Composer, client MySQL e l'integrazione con lo stack `yougo-dev`.

---

## Perché esiste

Claude Code gira dentro un devcontainer con firewall di rete stretto (`init-firewall.sh`) e senza accesso al file-system host. Questo va bene per sicurezza ma scomodo se il progetto richiede toolchain non incluse nell'immagine ufficiale (Java, PHP, Python, ecc.).

`claudebox` scarica il Dockerfile ufficiale di Anthropic e lo estende con patch idempotenti committati nella repo del progetto. I patch vengono **riapplicati automaticamente** ad ogni `init`/`update`, quindi aggiornare il Dockerfile upstream non rompe mai il setup custom.

---

## Requisiti

| Piattaforma | Requirement |
|---|---|
| Tutte | Docker Desktop o Docker Engine in esecuzione |
| macOS / Linux | `bash` (il default di sistema va bene, anche il bash 3.2 di macOS) |
| Windows | PowerShell 5.1+ (quello incluso in Windows 10/11) |

Il tuo account Claude deve essere già attivo sul sistema host: `claudebox` monta `~/.claude` in read-only dentro al container per le credenziali.

---

## Installazione (una tantum)

### macOS / Linux

```bash
bash claudebox.sh install
```

Lo script si copia in `~/.local/bin/claudebox`, aggiunge la cartella al `PATH` del tuo `.bashrc` o `.zshrc`, e da questo momento `claudebox` è invocabile da qualsiasi cartella.

### Windows

```powershell
.\claudebox.ps1
```

Lo script si copia in `%USERPROFILE%\bin\claudebox.ps1`, aggiunge la cartella al `PATH` utente e aggiunge un alias `claudebox` al profilo PowerShell.

Poi **riavvia il terminale** (o `source ~/.zshrc` / `. $PROFILE`) così il `PATH` nuovo viene caricato.

---

## Quick start

Dalla cartella del progetto:

```bash
claudebox start -y
```

Questo comando fa tutto da solo:

1. Scarica il Dockerfile ufficiale di Anthropic in `.devcontainer/`
2. Esegue automaticamente tutti i patch `patch-dockerfile*.sh` trovati nella repo
3. Builda l'immagine Docker
4. Avvia il container, applica il firewall, verifica l'isolamento
5. Lancia `claude --dangerously-skip-permissions` interattivo

Il flag `-y` salta i prompt di conferma. Togli `-y` se vuoi procedere un passo alla volta.

---

## Sistema dei patch Dockerfile

Questa è la feature centrale che rende claudebox adatto a progetti reali: i patch custom sono **file shell committati nella repo** che `claudebox` scopre e applica automaticamente.

### Come funziona

Claudebox cerca file che matchano il pattern `patch-dockerfile*.sh` (e `.ps1` su Windows) in due posizioni:

| Location | cwd di esecuzione | Convenzione `DOCKERFILE=` interna al patch |
|---|---|---|
| `./.devcontainer/patch-dockerfile*.sh` | `.devcontainer/` | `"Dockerfile"` (relativo) |
| `./patch-dockerfile*.sh` (project root) | project root | `".devcontainer/Dockerfile"` |

Entrambe le convenzioni coesistono. I patch vengono eseguiti in ordine alfabetico, prima quelli in `.devcontainer/` poi quelli in project root. Se l'ordine conta (un patch dipende da un altro), prefissali con un numero: `patch-dockerfile-10-java.sh`, `patch-dockerfile-20-php.sh`.

### Quando vengono eseguiti

I patch sono idempotenti — usano marker di inizio/fine per rilevare se sono già applicati. Vengono invocati da claudebox in tre punti:

1. **Fine di `init`** — subito dopo il download del Dockerfile pulito
2. **Fine di `update`** — dopo il ri-download che avrebbe cancellato le modifiche custom
3. **Inizio di `up`** — safety net, nel caso tu abbia aggiunto un patch dopo l'`init`

Questo significa che **aggiornare il Dockerfile ufficiale non rompe mai il setup custom**: i patch vengono riapplicati immediatamente.

---

## Patch inclusi

### `patch-dockerfile-java.sh` — Java 21 + Maven

Aggiunge Eclipse Temurin 21 JDK (via repo Adoptium) e Apache Maven 3.9.9 (da archive.apache.org). Il patch è **generico e riusabile** — può vivere sia in `.devcontainer/` che in project root grazie alla sua auto-discovery del Dockerfile.

Installa:

- **OpenJDK 21** headless con symlink cross-arch `/usr/local/java-21 -> /usr/lib/jvm/temurin-21-jdk-*`
- **Maven 3.9.9** in `/opt/maven`, con symlink in `/usr/local/bin/mvn` così è nel `PATH` standard anche se `$PATH` viene modificato da shell init script
- Export di `JAVA_HOME`, `MAVEN_HOME`, `PATH` in `/etc/profile.d/java-maven.sh` per le login shell

La versione di Maven è override-abile con la variabile d'ambiente `MAVEN_VERSION`:

```bash
MAVEN_VERSION=3.9.6 ./patch-dockerfile-java.sh patch
```

Comandi: `patch` (default), `remove`, `status`, `help`.

### `patch-dockerfile-uvx.sh` — uv + uvx (Python tooling)

Aggiunge [uv](https://docs.astral.sh/uv/) e `uvx` (alias di `uv tool run`) di Astral. Patch riusabile, scopribile da entrambe le location.

Installa:

- **`uv`** — Python package manager moderno (gestisce venv, lockfile, project, `pip` interface, install di interpreti Python)
- **`uvx`** — esegue tool Python in environment effimero senza installarli globalmente. Es:
  ```bash
  uvx ruff check .     # ruff senza installarlo
  uvx black .          # black senza installarlo
  uvx pytest           # pytest senza installarlo
  ```

Il patch usa il metodo raccomandato dalla [documentazione ufficiale](https://docs.astral.sh/uv/guides/integration/docker/): `COPY --from=ghcr.io/astral-sh/uv:<version> /uv /uvx /usr/local/bin/`. Vantaggi vs `curl ... | sh`:

- Build più veloce (no script di installazione)
- Pinning di versione esplicito e riproducibile
- Binari statici musl, niente dipendenze runtime
- Niente layer apt aggiuntivi

Variabili d'ambiente settate dal patch:

- `UV_TOOL_BIN_DIR=/usr/local/bin` — `uv tool install <pkg>` mette i binari direttamente nel `PATH`
- `UV_LINK_MODE=copy` — silenzia warning sui link cross-filesystem nei volumi devcontainer

Override versione:

```bash
UV_VERSION=0.11.8 ./patch-dockerfile-uvx.sh patch
```

Comandi: `patch` (default), `remove`, `status`, `help`.

### `patch-dockerfile.sh` — PHP 8 + Composer + rete `yougo-dev`

Patch **project-specific per yougo-dev**. Vive in project root (usa `DOCKERFILE=".devcontainer/Dockerfile"`). Installa:

- **PHP 8 CLI** con estensioni Symfony: mbstring, intl, xml, curl, mysql, zip, bcmath, gd, sqlite3
- **Composer** globale in `/usr/local/bin/composer`
- **mysql-client** per collegarsi al MySQL dello stack docker-compose
- **`unzip`** per i pacchetti Composer

Ha anche un comando `connect` che collega il container claudebox in esecuzione alla rete docker `yougo-dev`, in modo che possa parlare con `mysql:3306` e `keycloak:8080` dello stack compose parallelo.

Comandi: `patch` (default), `connect`, `status`, `help`.

---

## Workflow tipico per yougo-dev

```bash
# Avvia lo stack di supporto (MySQL, Keycloak)
docker compose up -d

# Avvia il devcontainer con tutti i patch
claudebox start -p work -y

# In un altro terminale, collega il devcontainer alla rete dello stack
./patch-dockerfile.sh connect
```

Il flag `-p work` usa un profilo separato (`~/.claude-work`) così le credenziali di lavoro restano isolate dal profilo personal. Dettagli sotto.

Dentro al devcontainer ora hai accesso a:

- `java`, `mvn` (da patch-dockerfile-java.sh)
- `php`, `composer`, `mysql` (da patch-dockerfile.sh)
- `mysql:3306` (user `yougo`, pwd `yougo`, db `yougo_new`) e `keycloak:8080` sulla rete interna

---

## Comandi claudebox

| Comando | Descrizione |
|---|---|
| `install` | Copia lo script in `PATH` utente, aggiunge alias al profilo shell |
| `start` | All-in-one: `init` (se serve) + patch + `build` + `run` + `claude` |
| `init` | Scarica Dockerfile e init-firewall.sh ufficiali Anthropic, genera `devcontainer.json`, applica i patch |
| `update` | Ri-scarica Dockerfile e init-firewall.sh (devcontainer.json invariato), riapplica i patch |
| `up` | Builda immagine + avvia container + verifica isolamento + lancia claude |
| `shell` | Apre una shell interattiva nel container in esecuzione |
| `stop` | Ferma il container senza rimuoverlo |
| `destroy` | Rimuove container + volume history + immagine del progetto |
| `help` | Mostra il reference |

### Flag comuni

| Flag | Descrizione |
|---|---|
| `-y` / `--yes` | Salta tutti i prompt di conferma |
| `-n` / `--no-update` | Non ricontrollare la versione di Claude Code su npm a ogni `up` |
| `-p <nome>` / `--profile <nome>` | Usa il profilo `<nome>` invece di `personal` |

---

## Sistema di profili

Un profilo è una cartella di configurazione Claude Code separata. Permette di avere **credenziali diverse per contesti diversi** (account personale vs lavoro vs cliente).

| Profilo | Cartella host montata read-only | Volume condiviso tra progetti |
|---|---|---|
| `personal` (default) | `~/.claude` | `claudebox-shared-config-personal` |
| `work` | `~/.claude-work` | `claudebox-shared-config-work` |
| `cliente-x` | `~/.claude-cliente-x` | `claudebox-shared-config-cliente-x` |

Il nome del container include il profilo (tranne `personal` per retrocompatibilità): `claudebox-<progetto>-<profilo>`. Questo significa che puoi avere **lo stesso progetto in due container diversi** con due account Claude distinti, senza conflitti.

Quando usi un profilo nuovo per la prima volta, claudebox seeda automaticamente il volume condiviso dal profilo `personal`, poi ti chiede di fare login. Le credenziali del nuovo profilo restano isolate.

---

## Scrivere un patch custom

Template minimo, idempotente, da copiare in `.devcontainer/patch-dockerfile-<nome>.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

DOCKERFILE="Dockerfile"
MARKER_BEGIN="# >>> MIO_PATCH_BEGIN >>>"
MARKER_END="# <<< MIO_PATCH_END <<<"

case "${1:-patch}" in
    patch)
        [ -f "$DOCKERFILE" ] || { echo "ERR: Dockerfile non trovato"; exit 1; }
        if grep -qF "$MARKER_BEGIN" "$DOCKERFILE"; then
            echo "OK: patch gia' applicato"
            exit 0
        fi
        cat >> "$DOCKERFILE" <<EOF

$MARKER_BEGIN
USER root
RUN apt-get update && apt-get install -y --no-install-recommends \\
        mia-libreria \\
    && rm -rf /var/lib/apt/lists/*
USER node
$MARKER_END
EOF
        echo "OK: patch applicato"
        ;;
    remove)
        sed -i.bak "/^${MARKER_BEGIN}$/,/^${MARKER_END}$/d" "$DOCKERFILE" || \
        sed -i '' "/^${MARKER_BEGIN}$/,/^${MARKER_END}$/d" "$DOCKERFILE"
        ;;
    *)
        echo "Uso: $0 [patch|remove]"; exit 1 ;;
esac
```

Punti chiave:

- **Markers univoci** per ogni patch (non copia-incollare quelli del Java o PHP patch)
- **Idempotenza**: controlla sempre il marker prima di appendere
- **`USER root` / `USER node`**: il Dockerfile finisce come `node`, torna a `node` alla fine del patch
- **Rete**: i patch vengono eseguiti durante la **build** (prima che il firewall sia applicato), quindi possono scaricare pacchetti. Non puoi assumere connettività libera a runtime.

---

## Troubleshooting

### `exit code 100` da apt-get durante la build

Il pacchetto non esiste nei repository del base image. Due cause tipiche:

1. **Nome pacchetto sbagliato** per la distro (es. `openjdk-21-jdk-headless` non è in tutte le versioni Debian/Ubuntu).
2. **Repo esterno mancante**: il pacchetto è in un PPA o apt repo terzo che va aggiunto.

Fix: aggiungi il repo corretto nel patch. Es. per Java usiamo il repo Adoptium invece di fidarci di quello default Debian.

### `NO_PUBKEY` quando apt prova a leggere un repo terzo

Stai scaricando la chiave GPG con `wget -qO /usr/share/keyrings/foo.gpg` ma la chiave è in formato ASCII armored (`-----BEGIN PGP PUBLIC KEY BLOCK-----`). Apt con `signed-by=...gpg` pretende il formato binario dearmored.

Fix:

```dockerfile
RUN wget -qO - https://example.com/key.pub \
    | gpg --dearmor -o /usr/share/keyrings/foo.gpg
```

### `curl: (22) ... 404` scaricando una release Apache (Maven, Tomcat, ecc.)

`dlcdn.apache.org` tiene **solo l'ultima patch** di ogni versione minor. Quando esce una patch nuova, quella vecchia sparisce dalla CDN.

Fix: scarica da `archive.apache.org/dist/` che conserva tutte le versioni per sempre:

```
https://archive.apache.org/dist/<progetto>/<percorso>
```

### I binari installati dal patch non sono nel `PATH` a runtime

La devcontainer.json di Anthropic definisce un `containerEnv.PATH` esplicito che **sovrascrive** quello del Dockerfile. Shell interattive (zsh/oh-my-zsh) possono fare altrettanto.

Fix: nel patch crea **symlink in `/usr/local/bin/`** (sempre nel PATH standard):

```dockerfile
RUN ln -sf /opt/tuobin/comando /usr/local/bin/comando
```

E/o scrivi gli export anche in `/etc/profile.d/mio-tool.sh`.

### Il patch funzionava, poi è sparito dopo un claudebox update

Questo era il bug originale risolto dall'auto-discovery. Se usi una versione vecchia di `claudebox.sh` che **non** chiama `apply_dockerfile_patches`, ogni `init`/`update` ri-scarica il Dockerfile pulito e cancella il patch.

Fix: usa la versione di `claudebox.sh` di questa repo (ha `apply_dockerfile_patches` chiamata in `cmd_init`, `cmd_update`, e `cmd_up`).

### Docker usa il cache e non applica un patch nuovo

Hai patchato il Dockerfile ma Docker riusa layer cached precedenti:

```bash
claudebox destroy         # rimuove container + immagine del progetto
claudebox start -y -n     # ricostruisce da zero
```

Oppure manualmente:

```bash
docker build --no-cache -t claudebox-img-$(basename $(pwd) | tr A-Z a-z) .devcontainer/
```

### `claudebox` builda un'immagine chiamata `claudebox-img-devcontainer`

Stai lanciando claudebox dall'interno della cartella `.devcontainer/`. Il nome del container deriva da `basename $(pwd)`, quindi diventa `devcontainer`. Esci e rilancia dalla project root.

---

## Struttura della repo

```
.
├── README.md                           <- questo file
├── claudebox.sh                        <- script principale (macOS/Linux)
├── claudebox.ps1                       <- script principale (Windows)
├── patch-dockerfile.sh                 <- patch project-specific (PHP + yougo-dev)
├── patch-dockerfile.ps1                <- idem per Windows
├── patch-dockerfile-java.sh            <- patch riusabile (Java 21 + Maven)
├── patch-dockerfile-java.ps1           <- idem per Windows
├── patch-dockerfile-uvx.sh             <- patch riusabile (uv + uvx)
├── patch-dockerfile-uvx.ps1            <- idem per Windows
└── .devcontainer/                      <- generato da claudebox init (gitignora o committa)
    ├── Dockerfile                      <- scaricato da Anthropic + patch appesi
    ├── Dockerfile.orig                 <- backup pre-patch (creato al primo run)
    ├── devcontainer.json               <- generato da claudebox (customizzato)
    └── init-firewall.sh                <- scaricato da Anthropic
```

### Cosa committare

**Sempre**:

- `claudebox.sh` / `claudebox.ps1`
- `patch-dockerfile*.sh` / `patch-dockerfile*.ps1`
- `README.md`

**Opzionale** (dipende dal team):

- `.devcontainer/` intera, se vuoi che chi clona abbia già tutto pronto senza dover lanciare `claudebox init`.
- Se la committi, aggiungi `.devcontainer/Dockerfile.orig` al `.gitignore`.

**Mai**:

- `~/.claude` o qualsiasi cosa dentro, quella cartella contiene credenziali personali.

---

## Aggiornare questa repo

Quando Anthropic rilascia una nuova versione di Claude Code o aggiorna il Dockerfile ufficiale:

```bash
claudebox update              # ri-scarica Dockerfile e init-firewall.sh, riapplica i patch
claudebox up                  # builda con la versione nuova
```

Non c'è mai bisogno di toccare i patch a mano — l'auto-discovery li rimette automaticamente.

Quando aggiungi un patch nuovo:

1. Crealo seguendo il template sopra
2. Salvalo come `.devcontainer/patch-dockerfile-<nome>.sh` o `./patch-dockerfile-<nome>.sh`
3. `claudebox up` — l'applica da solo grazie al safety net
4. Committa il patch nella repo

---

## Licenza

Script originali Anthropic ([anthropics/claude-code](https://github.com/anthropics/claude-code)) distribuiti sotto la loro licenza.
Il codice di `claudebox` e dei patch in questa repo è MIT (o quello che decidi di mettere).
