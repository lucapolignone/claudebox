# claude-dev

Strumento da terminale per configurare e avviare un **devcontainer isolato per Claude Code** nella cartella del progetto corrente.

Scarica i file ufficiali di Anthropic (`Dockerfile` e `init-firewall.sh`) direttamente dal repository [`anthropics/claude-code`](https://github.com/anthropics/claude-code), genera un `devcontainer.json` personalizzato con il nome del progetto, monta le credenziali esistenti di Claude Code dall'host (in sola lettura), e avvia il container con `claude --dangerously-skip-permissions` dopo aver verificato che l'isolamento sia corretto.

---

## Prerequisiti

- **Docker Desktop** (Windows, macOS) o **Docker Engine** (Linux) installato e in esecuzione
- **Claude Code** installato e configurato sull'host (credenziali valide in `~/.claude`)
- **PowerShell 5.1+** (Windows) oppure **bash/zsh** (macOS, Linux)

---

## Installazione

### Windows (PowerShell)

Scarica `claude-dev.ps1`, poi esegui:

```powershell
# Abilita l'esecuzione di script (una tantum)
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser

# Rimuovi il blocco "scaricato da internet"
Unblock-File .\claude-dev.ps1

# Auto-installazione: copia lo script in ~/.local/bin e aggiunge l'alias al profilo
.\claude-dev.ps1
```

Riavvia PowerShell (o esegui `. $PROFILE`), poi il comando `claude-dev` è disponibile ovunque.

### macOS / Linux

Scarica `claude-dev.sh`, poi esegui:

```bash
bash claude-dev.sh
```

Lo script si copia in `~/.local/bin/claude-dev` e aggiunge il PATH al tuo `.zshrc` o `.bashrc`.

Riavvia il terminale (o esegui `source ~/.zshrc`), poi il comando `claude-dev` è disponibile ovunque.

---

## Variabili d'ambiente

| Variabile | Default | Descrizione |
|---|---|---|
| `CLAUDE_CONFIG_DIR` | `~/.claude` | Cartella config e credenziali di Claude Code sull'host |
| `CCSTATUSLINE_CONFIG_DIR` | `~/.config/ccstatusline` | Cartella config di [ccstatusline](https://github.com/sirmalloc/ccstatusline) (opzionale) |

Se non impostate, vengono rilevate automaticamente. Per impostarle permanentemente:

**Windows:**
```powershell
[Environment]::SetEnvironmentVariable('CLAUDE_CONFIG_DIR', "$env:USERPROFILE\.claude", 'User')
```

**macOS / Linux:**
```bash
echo 'export CLAUDE_CONFIG_DIR="$HOME/.claude"' >> ~/.zshrc
```

### Docker Desktop — File Sharing (Windows e macOS)

Docker deve poter accedere alla cartella di configurazione di Claude Code. Se `claude-dev up` segnala un errore di accesso:

1. Apri **Docker Desktop → Settings → Resources → File Sharing**
2. Aggiungi il percorso di `CLAUDE_CONFIG_DIR` (es. `C:\Users\tuonome\.claude`)
3. Se usi ccstatusline, aggiungi anche `CCSTATUSLINE_CONFIG_DIR`
4. Clicca **Apply & Restart**

Su Linux questo passaggio non è necessario.

---

## Utilizzo

### Avvio rapido (tutto in un comando)

```bash
cd /percorso/del/tuo/progetto
claude-dev start
```

`start` mostra un riepilogo interattivo, chiede se aggiornare i file ufficiali Anthropic (se `.devcontainer/` esiste già), e poi esegue in sequenza `init` → `build` → `run` → verifica isolamento → `claude --dangerously-skip-permissions`.

### Comandi disponibili

| Comando | Descrizione |
|---|---|
| `claude-dev start` | Esegue tutto in automatico: init (se serve) + build + run + claude |
| `claude-dev init` | Scarica `Dockerfile` e `init-firewall.sh` da Anthropic, genera `devcontainer.json` |
| `claude-dev up` | Build immagine, avvio container, verifica isolamento, lancia claude |
| `claude-dev update` | Ri-scarica `Dockerfile` e `init-firewall.sh` da Anthropic (senza toccare `devcontainer.json`) |
| `claude-dev shell` | Apre una shell zsh nel container già avviato |
| `claude-dev stop` | Ferma il container (senza rimuoverlo) |
| `claude-dev destroy` | Rimuove container, volume history e immagine del progetto corrente |

### Flusso tipico

```bash
# Prima volta su un progetto
cd ~/progetti/mio-progetto
claude-dev start          # genera tutto e apre claude

# Volte successive
claude-dev start          # chiede se fare update, poi parte
# oppure, se vuoi solo riaprire senza rebuild:
claude-dev shell

# Aggiornare i file Anthropic senza ricreare tutto
claude-dev update
claude-dev up

# Pulizia completa del progetto
claude-dev destroy
```

---

## Architettura dei mount

```
Host                                    Container
─────────────────────────────────────────────────────────────────────
CLAUDE_CONFIG_DIR           →  /host-claude              (read-only)
CCSTATUSLINE_CONFIG_DIR     →  /host-ccstatusline        (read-only)

                               al primo avvio: cp -rn
                                      ↓
volume claude-dev-shared-config        →  /home/node/.claude
volume claude-dev-shared-ccstatusline  →  /home/node/.config/ccstatusline
volume claude-dev-<progetto>-history   →  /commandhistory
cartella progetto corrente             →  /workspace        (read-write)
```

**Perché questo schema:**

- `CLAUDE_CONFIG_DIR` è montata **read-only** in `/host-claude` — l'host non viene mai modificato dal container
- Claude Code lavora su un **volume Docker** (`claude-dev-shared-config`) con filesystem Linux nativo: niente problemi di operazioni atomiche su filesystem NTFS/Windows
- Le credenziali vengono copiate dall'host al volume **solo al primo avvio** (quando `.credentials.json` non esiste ancora nel volume)
- Il volume `claude-dev-shared-config` è **condiviso tra tutti i devcontainer** — stesse credenziali e configurazioni per tutti i progetti
- Il volume history è **per-progetto** — la history della shell non si mescola tra progetti diversi
- Le modifiche al codice in `/workspace` sono immediatamente visibili nell'IDE sull'host

---

## File generati in `.devcontainer/`

| File | Origine | Note |
|---|---|---|
| `Dockerfile` | Scaricato da `anthropics/claude-code` | Immagine ufficiale Anthropic |
| `init-firewall.sh` | Scaricato da `anthropics/claude-code` | Firewall ufficiale Anthropic |
| `devcontainer.json` | Generato da claude-dev | Personalizzato con nome progetto e mount config |

`claude-dev update` aggiorna solo `Dockerfile` e `init-firewall.sh` senza toccare `devcontainer.json`.

Puoi committare `.devcontainer/` nel repository per condividere la configurazione con il team — ogni sviluppatore dovrà solo avere `CLAUDE_CONFIG_DIR` impostata con le proprie credenziali.

---

## Volumi Docker condivisi

| Volume | Mount nel container | Contenuto |
|---|---|---|
| `claude-dev-shared-config` | `/home/node/.claude` | Credenziali e configurazioni Claude Code |
| `claude-dev-shared-ccstatusline` | `/home/node/.config/ccstatusline` | Configurazione ccstatusline |
| `claude-dev-<progetto>-history` | `/commandhistory` | History shell specifica del progetto |

Per azzerare le configurazioni condivise (es. dopo aver aggiornato le credenziali sull'host):

```bash
docker volume rm claude-dev-shared-config claude-dev-shared-ccstatusline
```

Al prossimo `claude-dev up` i volumi vengono ricreati e le config ricopiate dall'host.

---

## Sicurezza

- Claude Code gira con `--dangerously-skip-permissions` perché il container stesso è il sandbox
- Il filesystem dell'host è inaccessibile tranne `/workspace` (il progetto corrente) e le cartelle config montate read-only
- Il firewall `init-firewall.sh` (ufficiale Anthropic) limita il traffico di rete in uscita a: Anthropic API, npm registry, GitHub, statsig, sentry
- Su Windows/macOS il firewall potrebbe non attivarsi (`NET_ADMIN` non disponibile) — l'isolamento del filesystem rimane comunque attivo
- Le credenziali Claude non vengono mai scritte nell'immagine Docker

---

## Compatibilità

| Piattaforma | Script | Note |
|---|---|---|
| Windows 10/11 | `claude-dev.ps1` | Richiede Docker Desktop e PowerShell 5.1+ |
| macOS | `claude-dev.sh` | Richiede Docker Desktop |
| Linux | `claude-dev.sh` | Richiede Docker Engine; nessuna configurazione File Sharing necessaria |
