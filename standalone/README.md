# Pacchetto standalone offline di CircuitVerse

Questa cartella produce un archivio `.zip` distribuibile su PC Windows 10/11
a 64 bit **senza connessione a internet**. Si estrae e si avvia con un doppio
clic: non c'è nulla da installare.

- ZIP pronto: `CircuitVerse-Offline-Windows-x64.zip` (~32 MB)
- Estratto: ~105 MB
- Serve solo un browser già installato (Edge, Chrome, Firefox)

## Come si usa (utente finale)

1. Estrai lo zip dove preferisci.
2. Doppio clic su **Avvia CircuitVerse.cmd** → si apre il browser su
   `http://127.0.0.1:3000`.
3. Per chiudere: doppio clic su **Ferma CircuitVerse.cmd**.

Istruzioni complete per l'utente: `launcher/README-ISTRUZIONI.txt` (finisce
dentro lo zip).

## Come si ricostruisce (sviluppatore)

Su una macchina **con internet**, con Node.js installato:

```powershell
.\standalone\build.ps1
```

Lo script:

1. esegue `npm ci` in `cv-frontend-vue` (salvo `-SkipInstall` se `node_modules` c'è già);
2. compila il frontend con `VITE_STANDALONE=1` e `VITE_BASE=/`;
3. **verifica** che il bundle non chieda risorse di rete al boot (se ne chiede, la build fallisce);
4. assembla `standalone/dist/` con app, `caddy.exe` e gli script di avvio;
5. crea lo zip.

Parametri: `-SkipInstall`, `-SkipZip`.

### Il gate "offline"

`build.ps1` fallisce se nel bundle compare una di queste stringhe:

```
ajax.googleapis.com   fonts.googleapis.com   fonts.gstatic.com   googletagmanager.com
```

Sono le risorse che il simulatore scarica **all'avvio senza che l'utente faccia
niente**: se una di queste finisce nel pacchetto, il pacchetto non è autonomo.

Una seconda lista, `advisory`, segnala senza bloccare i link che si aprono solo
su clic (manuale, forum, EDA Playground, imgur nel dialog "Report issue" che
nella build offline non viene montato). Sono degradabilie documentati nel README
per l'utente.

## Struttura

```
standalone/
├── build.ps1                  # build + gate + zip
├── launcher/                  # script che finiscono dentro lo zip
│   ├── Avvia CircuitVerse.cmd # doppio clic
│   ├── Avvia.ps1              # logica: porta, Caddy, browser
│   ├── Ferma CircuitVerse.cmd
│   ├── Ferma.ps1
│   └── README-ISTRUZIONI.txt  # istruzioni per l'utente finale
├── vendor/caddy.exe           # server statico (~50 MB)
└── dist/                      # pacchetto assemblato (output)
```

## Modifiche al frontend

Tutte le modifiche stanno nel submodule `cv-frontend-vue` e sono **condizionate**
dal flag `VITE_STANDALONE=1`, così il comportamento con il backend Rails resta
identico quando il flag non è impostato. Il file chiave è
`cv-frontend-vue/src/standalone.ts`.

Cosa fa il flag:

| Area | Comportamento offline |
|---|---|
| `globalVariables.ts` | forza `isUserLoggedIn=false`, `logixProjectId` assente, `embed=false` |
| `pages/simulatorHandler.vue` | salta `checkEditAccess` / `getLoginData` (aggiunto anche il `.catch` mancante) |
| `simulator/src/setup.js` | salta il caricamento del progetto dal backend |
| `simulator/src/data/save.js` | "Save Online" non tenta più il server |
| `simulator/src/data/project.ts` | "New Project" azzera il canvas invece di navigare a `/simulator/` |
| `components/Navbar/*` | via Sign in / Register / Dashboard / Groups / Report Issue |
| `simulator/src/Verilog2CV.js` | usa la sintesi WASM invece di `POST /api/v1/simulator/verilogcv` |
| `locales/i18n.ts` | lingua predefinita italiano |

Fix applicati che valgono anche per la build con backend:

- `v0/index.html`: rimosso `<script>` jQuery da CDN (il pacchetto non ha rete);
- `main.ts`: `globalVariables` importato per primo, altrimenti jQuery UI (UMD)
  si aggancia al `jQuery` globale non ancora definito;
- `router/index.ts`: `createWebHistory(import.meta.env.BASE_URL)`;
- `data/load.js`: `__projectName` non era definito da nessuna parte;
- `listeners.js`: i listener Tauri erano chiamati **a livello di modulo** anche
  nel browser, dove `listen()` solleva 19 errori;
- `plotArea.js`: `resize()` leggeva `#plot.clientWidth` senza controllare l'esistenza
  (il diagramma temporale è smontato in modalità Verilog);
- `modules/ImageAnnotation.js`: l'upload imgur è stato sostituito con un data URL
  locale (niente terze parti, niente chiave API nel client).

Sintesi Verilog in browser: `simulator/src/synthesis/` è stato portato da
`v1/` a `src/`, insieme all'auto-layout dei circuiti sintetizzati.

## Note sul launcher

- **Bind su `127.0.0.1`**: scrivere `localhost` non basta, Caddy lo risolve e
  si mette in ascolto su `::` (tutte le interfacce), esponendo il simulatore
  alla rete locale e facendo comparire il prompt di Windows Firewall.
- **Endpoint di amministrazione** su porta dedicata (13000+): quella di default
  (2019) è unica per macchina.
- **Stato di Caddy** in `%LOCALAPPDATA%\CircuitVerseStandalone`: dentro il
  pacchetto le directory annidate supererebbero il limite di 260 caratteri.
- **`-NoBrowser`** non apre il browser: utile per test automatici e chioschi.
- La porta viene scelta con un bind reale (`TcpListener`), non con
  `Get-NetTCPConnection`, che può rispondere in ritardo.