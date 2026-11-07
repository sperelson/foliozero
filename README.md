# FolioZero

FolioZero is a document management server for a headless Mac. It does the job of
[Paperless-ngx](https://github.com/paperless-ngx/paperless-ngx): it takes in your
paper documents, photos, emails and web pages, extracts their text, files them, tags
them and makes them searchable.

## Why this project exists

Paperless-ngx is excellent, but on a Mac it runs in Docker, with Python, Redis,
Celery, Tika and Gotenberg in the stack. On an always-on Mac mini that is a Linux VM
and half a dozen services to keep alive, just to file PDFs.

FolioZero is a port of Paperless-ngx (reference version 3.4.2) to native Swift. It is
one binary, `foliozero`, that runs in a terminal or as a launchd service. It uses the
frameworks that macOS already has:

- **Vision** for OCR and barcodes, **PDFKit** and **Core Graphics** for PDFs and
  searchable archive PDFs, **ImageIO** for photos (HEIC included), **QuickLook** for
  thumbnails.
- **WebKit** to capture web pages, HTML files and emails as PDFs. Web pages are
  first-class input: post a URL, or drop a `.webloc`, `.url` or `.webarchive` file.
- **Apple Intelligence** (the on-device foundation model) for AI suggestions, similar
  documents and chat about your documents. Document text never leaves the Mac.

It speaks the Paperless-ngx REST API (versions 9 and 10) and serves the official
Paperless-ngx web interface. Existing mobile apps, scanner uploads and scripts work
against it unchanged.

What it supports:

- PDFs, photos (HEIC, JPEG, PNG, TIFF, WebP, ...), text, Office files, emails (`.eml`)
  and web pages.
- Tags, correspondents, document types, storage paths, custom fields, notes, trash,
  history, document versions, share links and share link bundles.
- Matching rules (any, all, exact, regex, fuzzy) and a trained classifier for "Auto".
- Full-text search with the Paperless-ngx query syntax.
- Workflows, mail rules (IMAP, with Gmail and Outlook OAuth), a consume folder with
  subfolders as tags, barcodes (separator pages, ASN, tags), double-sided collation.
- Users, groups, object permissions, TOTP two-factor login and OpenID Connect sign-in.
- Import and export in the Paperless-ngx `document_exporter` format.

FolioZero is not affiliated with the Paperless-ngx project. An AI coding agent wrote
it from the Paperless-ngx source; see [How it was built](#how-it-was-built). See
[docs/DESIGN.md](docs/DESIGN.md) for the architecture.

## Dependencies

### To build

- A Mac with Apple silicon and Xcode 27 (Swift 6.4). The package targets macOS 27.
- Network access on the first build, so SwiftPM can fetch the Swift packages below.

### To run

- A Mac with Apple silicon on macOS 27. Nothing else is required.
- The binary links only macOS system libraries. The Swift packages are compiled into it.

### Swift packages (compiled into the binary)

| Package | Use | License |
|---|---|---|
| [GRDB.swift](https://github.com/groue/GRDB.swift) | SQLite database, FTS5 full-text search | MIT |
| [Hummingbird](https://github.com/hummingbird-project/hummingbird) and [hummingbird-websocket](https://github.com/hummingbird-project/hummingbird-websocket) | HTTP server, WebSocket status updates | Apache 2.0 |
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) | Command-line interface | Apache 2.0 |
| [swift-log](https://github.com/apple/swift-log) | Logging | Apache 2.0 |
| [swift-http-types](https://github.com/apple/swift-http-types) | HTTP types | Apache 2.0 |
| [MultipartKit](https://github.com/vapor/multipart-kit) | File uploads | MIT |
| [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) | Office files, export zips, bundles | MIT |

These pull in SwiftNIO, swift-crypto, swift-nio-ssl, async-http-client and other
Apple and Swift Server packages, all under Apache 2.0. `Package.resolved` pins every
version. ZIPFoundation is pinned to an unreleased commit, because the 0.9.20 manifest
causes a build warning.

### Apple frameworks (part of macOS)

Vision, PDFKit, Core Graphics, ImageIO, WebKit, QuickLook, AppKit, NaturalLanguage
(sentence embeddings for the AI index), FoundationModels (Apple Intelligence),
CryptoKit, FSEvents and launchd.

### Downloaded at run time

- **The Paperless-ngx web interface** (v3.4.2, GPL-3.0). FolioZero does not ship it.
  It downloads the release from GitHub, checks its SHA-256 and extracts its `static`
  folder. The download is 332 MB; the installed folder takes about 550 MB.

### Optional tools

FolioZero finds these in `PATH` (Homebrew paths included) when they are installed.
`foliozero doctor` reports which ones it found.

| Tool | Install | Use |
|---|---|---|
| Tesseract | `brew install tesseract tesseract-lang` | OCR for languages Vision lacks, for example Afrikaans (`OCR_ENGINE=tesseract`) |
| Ghostscript | `brew install ghostscript` | PDF/A archive files (`OCR_OUTPUT_TYPE=pdfa`) |
| LibreOffice | `brew install --cask libreoffice` | Archive PDFs of Office files; text of legacy `.xls` and `.ppt` |
| Ollama, or an OpenAI-compatible API | | AI backend if Apple Intelligence is not available |

## Build

```sh
git clone git@github.com:sperelson/foliozero.git
cd foliozero
Tools/build.sh
```

`Tools/build.sh` makes a release build and copies the binary to `./foliozero` in the
project root (git ignores it). It prints the version when it finishes. Pass extra
`swift build` options after it, for example `Tools/build.sh --scratch-path /tmp/fz-build`.

The result is one arm64 executable of about 43 MB. The linker signs it ad hoc, which
is enough for it to run on another Mac.

For development:

```sh
swift build
swift test
```

One test serves a real Paperless-ngx 3.4.2 web interface. It runs only when
`FOLIOZERO_TEST_FRONTEND_DIR` points at the `static` folder of that release, for
example the `<home>/static` folder that `foliozero frontend install` creates.

## Copy the binary to a headless Mac

The target Mac needs Apple silicon and macOS 27. Turn on **Remote Login** on it first
(see [Prepare the Mac](#1-prepare-the-mac)). Then, from the build Mac:

```sh
scp foliozero <user>@<mac>.local:/tmp/foliozero
ssh -t <user>@<mac>.local 'sudo mkdir -p /usr/local/bin && sudo install -m 755 /tmp/foliozero /usr/local/bin/foliozero && rm /tmp/foliozero'
ssh <user>@<mac>.local '/usr/local/bin/foliozero --version'
```

`/usr/local/bin` is not in the default `PATH` of a non-interactive SSH command, so
use the full path there. In an interactive shell, `foliozero` works on its own.

A binary copied with `scp` or `rsync` runs as is. A binary that arrives through
AirDrop, a browser or a mail client gets a quarantine flag, and Gatekeeper blocks it.
Remove the flag:

```sh
sudo xattr -d com.apple.quarantine /usr/local/bin/foliozero
```

## Setup

### 1. Prepare the Mac

Do this once, with a display attached or through Screen Sharing.

1. **Sharing.** In System Settings > General > Sharing, turn on **Remote Login** (SSH)
   and **Screen Sharing**. You need Screen Sharing later for Apple Intelligence and for
   automatic login. A Mac without a display may offer a low resolution; an HDMI dummy
   plug helps.
2. **Sleep and power.** Stop the Mac from sleeping, and make it start again after a
   power cut:
   ```sh
   sudo pmset -a sleep 0 disksleep 0 autorestart 1
   ```
3. **Login and FileVault.** Decide how FolioZero starts (see
   [Run as a service](#run-as-a-service)):
   - A LaunchAgent needs **automatic login** for the account that runs FolioZero
     (System Settings > Users & Groups > Automatically log in as). macOS does not offer
     automatic login while FileVault is on.
   - A LaunchDaemon starts at boot without a login. With FileVault on, a restarted Mac
     still waits at the unlock screen until someone enters a password. For planned
     restarts, use `sudo fdesetup authrestart`.
4. **Firewall.** If the macOS firewall is on, allow FolioZero. Nobody can answer the
   firewall prompt on a headless Mac:
   ```sh
   sudo /usr/libexec/ApplicationFirewall/socketfilterfw --add /usr/local/bin/foliozero
   sudo /usr/libexec/ApplicationFirewall/socketfilterfw --unblockapp /usr/local/bin/foliozero
   ```
5. **Folder privacy.** Keep the data and consume folders out of Desktop, Documents,
   Downloads, iCloud Drive, external drives and network shares. macOS asks for
   permission before a process reads those places, and nobody can answer that prompt
   on a headless Mac. The default data folder, `~/Library/Application Support/FolioZero`,
   needs no permission. If you must use one of those places, give
   `/usr/local/bin/foliozero` Full Disk Access in System Settings > Privacy & Security.

### 2. Turn on Apple Intelligence

FolioZero's AI features use Apple's on-device model by default. They are optional and
off until you set `FOLIOZERO_AI_ENABLED=true`. Everything else works without them.

Requirements (from Apple):

- A Mac with Apple silicon.
- At least 7 GB of free storage for the model.
- The Mac's language and the Siri language set to the same supported language.
  English (South Africa), English (UK), English (US) and the other English variants
  all work.

Steps:

1. Connect with Screen Sharing and sign in as the account that will run FolioZero.
2. Open System Settings > Apple Intelligence & Siri.
3. Check the language, then turn on the **Apple Intelligence** switch.
4. Wait for the model to download. This runs in the background and can take a while.
   The Mac must stay awake and online.

When the model is not usable, FolioZero tells you why in the web interface and the log:

| Message | Cause |
|---|---|
| This Mac does not support Apple Intelligence. | Intel Mac, or another unsupported Mac |
| Apple Intelligence is turned off. | The switch in step 3 is off for this account |
| The on-device model is not ready yet | The model is still downloading |

Notes:

- The AI index (similar documents, and the sources for chat) uses NaturalLanguage
  sentence embeddings. These work without Apple Intelligence.
- Without Apple Intelligence, use another backend. For Ollama on the same Mac:
  `FOLIOZERO_AI_LLM_BACKEND=ollama`, `FOLIOZERO_AI_LLM_MODEL=llama3.1`. For an
  OpenAI-compatible API: `FOLIOZERO_AI_LLM_BACKEND=openai`, plus `_AI_LLM_ENDPOINT`,
  `_AI_LLM_MODEL` and `_AI_LLM_API_KEY`. With these backends, document text leaves
  the Mac.
- The on-device model has a much smaller context window than large hosted models.
  FolioZero shortens long documents to fit.

### 3. Create the configuration

Data lives in `~/Library/Application Support/FolioZero` unless you pass `--home` or set
`FOLIOZERO_HOME`. Settings come from `<home>/foliozero.conf` (`KEY=VALUE` lines), the
environment, or `--set KEY=VALUE` on the command line, in rising order of precedence.

Settings use the Paperless-ngx names with a `FOLIOZERO_` prefix. `PAPERLESS_` names work
too, so you can reuse an existing `paperless.conf`. A starting point:

```sh
mkdir -p ~/Library/Application\ Support/FolioZero
cat > ~/Library/Application\ Support/FolioZero/foliozero.conf <<'EOF'
FOLIOZERO_TIME_ZONE=Africa/Johannesburg
FOLIOZERO_URL=http://mac-mini.local:8000
FOLIOZERO_DATE_ORDER=DMY
FOLIOZERO_FILENAME_FORMAT={{ created_year }}/{{ correspondent }}/{{ title }}
FOLIOZERO_AI_ENABLED=true
EOF
foliozero config        # shows the effective settings and paths
```

Common settings:

| Setting | Default | Meaning |
|---|---|---|
| `FOLIOZERO_PORT` | `8000` | HTTP port |
| `FOLIOZERO_BIND_ADDR` | `::` | All interfaces. Use `127.0.0.1` for local access only |
| `FOLIOZERO_URL` | none | The URL people use to reach the server |
| `FOLIOZERO_TIME_ZONE` | system | e.g. `Africa/Johannesburg` |
| `FOLIOZERO_OCR_LANGUAGE` | `eng` | `eng+afr`, `deu`, ... |
| `FOLIOZERO_OCR_ENGINE` | `vision` | `tesseract` for languages Vision lacks (Afrikaans) |
| `FOLIOZERO_OCR_MODE` | `auto` | `auto`, `redo`, `force`, `off` |
| `FOLIOZERO_REMOTE_OCR_ENGINE` | none | `azureai` sends OCR to Azure AI Document Intelligence; also set `_API_KEY`, `_ENDPOINT` and `_MODE` (`always` or `workflow_only`) |
| `FOLIOZERO_FILENAME_FORMAT` | id | e.g. `{{ created_year }}/{{ correspondent }}/{{ title }}` |
| `FOLIOZERO_CONSUMER_SUBDIRS_AS_TAGS` | `false` | Folder names in the consume folder become tags |
| `FOLIOZERO_DATE_ORDER` | `DMY` | Order for dates like 03/04/2026 |
| `FOLIOZERO_FRONTEND_DIR` | `<home>/static` | The `static` folder of a Paperless-ngx release |
| `FOLIOZERO_FRONTEND_AUTO_INSTALL` | `true` | `serve` downloads the web interface when it is missing |
| `FOLIOZERO_AI_ENABLED` | `false` | AI suggestions, similar documents and chat |
| `FOLIOZERO_AI_LLM_BACKEND` | `apple` | `apple` (on-device), `openai` or `ollama` |
| `FOLIOZERO_AUTO_LOGIN_USERNAME` | none | Signs every visitor in as this user. Never expose such a server |

Paperless-ngx's [configuration documentation](https://docs.paperless-ngx.com/configuration/)
describes most other settings. Settings that exist only for Docker, Redis, Celery, Tika
or Gotenberg do not apply.

### 4. Check the installation and create a user

```sh
foliozero doctor                          # folders, database, frontend, optional tools
foliozero user create admin --superuser   # prompts for a password
```

### 5. Install the web interface

`foliozero serve` downloads and installs the Paperless-ngx v3.4.2 web interface in the
background on its first start. The API works meanwhile, and the web interface appears
when the install finishes. To install it by hand first:

```sh
foliozero frontend install            # --force downloads it again
```

Every attempt is logged to `<home>/data/log/frontend-install.log`. A failed attempt is
retried on the next start. Set `FRONTEND_AUTO_INSTALL=false` to stop the download, or
point `FRONTEND_DIR` at a `static` folder of your own. A set `FRONTEND_DIR` always wins.

### 6. Optional: move from Paperless-ngx

Export from Paperless-ngx with `document_exporter`, copy the folder or zip to the Mac,
then:

```sh
foliozero import /path/to/export      # a folder with manifest.json, or a zip file
```

Passwords keep working, because FolioZero uses the same Django PBKDF2 hashes.

### 7. Optional: Gmail and Outlook mail accounts

Mail rules can read Gmail and Outlook accounts through OAuth instead of a password.
Register an OAuth client with Google or Microsoft, with `<base>/api/oauth/callback/`
as its redirect URI. Then set these values:

| Setting | Meaning |
|---|---|
| `FOLIOZERO_OAUTH_CALLBACK_BASE_URL` | The public URL of this server, e.g. `https://docs.example.com`; defaults to `FOLIOZERO_URL` |
| `FOLIOZERO_GMAIL_OAUTH_CLIENT_ID`, `FOLIOZERO_GMAIL_OAUTH_CLIENT_SECRET` | The Google OAuth client |
| `FOLIOZERO_OUTLOOK_OAUTH_CLIENT_ID`, `FOLIOZERO_OUTLOOK_OAUTH_CLIENT_SECRET` | The Microsoft OAuth client |

The Mail page then shows a button for each configured provider. After the consent
page, FolioZero adds the account. Enter the email address as the username. FolioZero
refreshes the access token when it expires.

### 8. Optional: sign-in with OpenID Connect

FolioZero reads the Paperless-ngx social login settings. It supports the
`openid_connect` provider, for example Authelia, Authentik, Keycloak, Google or
Microsoft Entra ID.

```sh
FOLIOZERO_APPS=allauth.socialaccount.providers.openid_connect
FOLIOZERO_SOCIALACCOUNT_PROVIDERS='{"openid_connect": {"APPS": [{"provider_id": "keycloak", "name": "Keycloak", "client_id": "paperless", "secret": "<CLIENT_SECRET>", "settings": {"server_url": "https://<KEYCLOAK_SERVER>/realms/<REALM>"}}]}}'
```

Register `https://<host>/accounts/oidc/<provider_id>/login/callback/` as the redirect
URI at the provider. Set `FOLIOZERO_ACCOUNT_DEFAULT_HTTP_PROTOCOL=http` when clients
reach FolioZero without HTTPS. These settings work as in Paperless-ngx:
`SOCIAL_AUTO_SIGNUP`, `SOCIALACCOUNT_ALLOW_SIGNUPS`, `SOCIAL_ACCOUNT_DEFAULT_GROUPS`,
`ACCOUNT_DEFAULT_GROUPS`, `SOCIAL_ACCOUNT_SYNC_GROUPS`, `SOCIAL_ACCOUNT_SYNC_GROUPS_CLAIM`,
`SOCIAL_ACCOUNT_SYNC_SUPERUSER_GROUP`, `SOCIAL_ACCOUNT_SYNC_STAFF_GROUP`,
`SOCIAL_ACCOUNT_MFA_TRUSTED_AMR`, `DISABLE_REGULAR_LOGIN`, `REDIRECT_LOGIN_TO_SSO` and
`LOGOUT_REDIRECT_URL`.

## Run in a terminal

```sh
foliozero serve
```

This starts everything in one process: the web interface and API on port 8000, the
consume folder watcher, the task workers and the scheduled jobs (mail, classifier
training, sanity checks, the AI index). Open `http://<mac>.local:8000/` and sign in.

- Override settings for one run: `foliozero serve --set PORT=8010 --set BIND_ADDR=127.0.0.1`.
- Use another data folder: `foliozero serve --home /path/to/folder`.
- Log debug output: `foliozero serve -v`.
- Press Ctrl-C to stop. Running tasks get up to 30 seconds to finish.
- Logs go to the terminal and to `<home>/data/log/foliozero.log`.
- Over SSH, the server stops when the connection closes. Run it inside `tmux`, or
  install it as a service.

Drop files into `<home>/consume` while the server runs, and it picks them up. The
command line works with or without a running server:

```sh
foliozero consume ~/Scans/invoice.pdf ~/Pictures/receipt.heic
foliozero add-url https://example.com/article
foliozero list
foliozero search 'correspondent:eskom created:[2026 to now]'
foliozero show 1
foliozero help                        # all commands; `foliozero help <command>` for one
```

Maintenance commands: `sanity-check`, `rename`, `retag`, `reprocess`, `thumbnails`,
`train`, `empty-trash`, `index reindex`, `index optimize`, `export`, `import`.

Please note: the first OCR after you install or replace the binary takes about a
minute, because macOS compiles Vision's text recognition model for it. Later
documents take about a second per page.

## Run as a service

`foliozero service install` writes a launchd plist that runs `foliozero serve`, and
starts it. launchd starts it again if it crashes. The plist records the path of the
binary that installed it, so install from `/usr/local/bin/foliozero`, not from a build
folder (or pass `--binary <path>`).

Choose one of two kinds.

### LaunchAgent (default)

The service runs in the logged-in session of your account. Vision OCR, WebKit page
capture and QuickLook thumbnails work best there. On a headless Mac, turn on automatic
login for this account (see [Prepare the Mac](#1-prepare-the-mac)).

```sh
foliozero service install     # writes ~/Library/LaunchAgents/com.foliozero.server.plist
foliozero service status
foliozero service logs -f     # follow <home>/data/log/foliozero.log
foliozero service restart
foliozero service stop        # until the next start or reboot
foliozero service start
foliozero service uninstall   # removes the plist; your documents stay
```

### LaunchDaemon

The service starts at boot, before anyone logs in, and runs as your account. Use this
when FileVault is on or you do not want automatic login.

```sh
sudo foliozero service install --system --user "$USER" \
  --home "$HOME/Library/Application Support/FolioZero"
sudo foliozero service status --system
foliozero service logs -f
sudo foliozero service restart --system
sudo foliozero service uninstall --system
```

- Always pass `--home`. Without it, the daemon uses root's home folder.
- After the install, the command suggests `foliozero service logs --system`. That
  flag does not exist; use `foliozero service logs`.
- Tested: the daemon starts after a reboot, before login, and Apple Intelligence
  features work. Not yet confirmed: WebKit page capture and Vision OCR in this mode.
  If web capture fails, FolioZero keeps the extracted text without a rendered archive
  PDF and logs a warning.

launchd's own output goes to `<home>/data/log/launchd.out.log` and `launchd.err.log`.

### Upgrade the binary

There is no update mechanism (see below). To upgrade by hand:

```sh
mkdir -p ~/FolioZero-backup
foliozero export ~/FolioZero-backup            # back up first
# on the build Mac: git pull && Tools/build.sh, then copy the binary as above
foliozero service restart                      # add sudo and --system for a LaunchDaemon
foliozero --version
```

Database migrations run when the new binary starts. There is no way back to an older
schema except the backup.

## Problems and shortcomings

FolioZero is a personal project. An AI agent wrote it, and it has run on one Mac.
Know what you give up before you trust it with your documents.

### It will get out of date

- FolioZero copies the behaviour of Paperless-ngx 3.4.2. Paperless-ngx keeps
  releasing. Nothing here follows those releases automatically. Each new feature or
  fix must be ported by hand.
- The web interface is pinned to v3.4.2 by URL and SHA-256. A newer Paperless-ngx web
  interface may call endpoints that FolioZero does not have. Stay on v3.4.2.
- The API reports version 3.4.2. Apps and scripts that need a newer API may fail.
- The binary is built against the macOS 27 SDK. A future macOS release can change how
  Vision, WebKit, FoundationModels or launchd behave.
- `Package.resolved` pins the Swift packages, and ZIPFoundation is pinned to an
  unreleased commit. Security fixes in them arrive only when someone updates and
  rebuilds.

### There is no easy way to upgrade

- There are no releases, no signed or notarized binaries, no Homebrew formula, no
  installer and no automatic updates. You build, copy and restart by hand.
- The update check in the web interface is hidden on purpose. It would report
  Paperless-ngx releases, which do not apply here.
- Migrations are one way. Back up before every upgrade.
- macOS ties privacy and firewall permissions to the binary's ad-hoc signature, which
  changes with every build. You may have to grant them again after an upgrade.
- The first OCR after every upgrade takes about a minute.

### Other shortcomings

- **Not Paperless-ngx.** Not affiliated with it, not supported by its community, and
  never security-audited. Run it on a trusted network.
- **No HTTPS.** The server speaks plain HTTP. For access from outside your network,
  put a reverse proxy such as Caddy or nginx in front of it, or use a VPN.
- **Mac only.** Apple silicon and macOS 27 only. SQLite only; no PostgreSQL or MariaDB.
  One process on one machine; no scaling out.
- **Partly tested against real services.** Gmail and Outlook OAuth, OpenID Connect
  sign-in and Azure remote OCR pass local tests with fake servers. None has done a
  round trip against the real service.
- **Known gaps** (they stay as they are):
  - OpenID Connect supports only the `openid_connect` provider: no GitHub or other
    allauth providers, and no headless `/api/auth/headless/` API. A provider that signs
    tokens with an algorithm outside RS, PS, ES, EdDSA and HS fails. Half-finished
    sign-ins are lost on a restart.
  - The OCRmyPDF options in the application configuration (`unpaper_clean`, `deskew`,
    `rotate_pages_threshold`, `max_image_pixels`, `color_conversion_strategy`,
    `user_args`) are stored but have no effect. Vision and Tesseract have no equivalent.
  - Archive PDFs are PDFs with a text layer, not validated PDF/A, unless Ghostscript is
    installed and `OCR_OUTPUT_TYPE=pdfa` is set.
  - Mail OAuth state lives in memory. After a restart, reload the Mail page before you
    connect an account.
  - A share link bundle that is being built during a restart fails with "Interrupted".
    Press Retry.
  - `POST /api/workflow_triggers/` and `/api/workflow_actions/` on their own are not
    supported. The web interface never sends them.
  - A mail rule with an empty maximum age gets 30 days. Paperless-ngx rejects it.
  - Thumbnails are JPEG, not WebP.
- **Branding.** The web interface still says Paperless-ngx. FolioZero only adds
  "Powered by FolioZero" under the version in the sidebar.

### What you get in return

- **One binary.** No Docker, Python, Redis, Celery, Tika, Gotenberg or database server
  to install, update or keep running.
- **Native macOS.** Vision OCR, PDFKit, WebKit and QuickLook do the heavy work. launchd
  runs the service.
- **Private AI.** With Apple Intelligence, suggestions and chat run on the Mac. No
  API keys, no cost per request, and no document text sent anywhere.
- **Compatible.** The same web interface and API as Paperless-ngx 3.4.2, so existing
  apps, scanners and scripts work. It reads `paperless.conf` settings and imports
  Paperless-ngx exports, so you can move in, and move back out.
- **Web pages as documents.** Save articles, receipts and order pages by URL.
- **Your data in one folder.** One SQLite database and your files, in
  `~/Library/Application Support/FolioZero`.

## How it was built

FolioZero was written with [Claude Code](https://claude.com/claude-code), Anthropic's
AI coding agent, starting on 7 November 2026.

- **The brief.** Whatever Paperless-ngx supports, FolioZero should support, on a
  headless Mac, with PDFs, photos and web pages as the main inputs. The project owner
  made the product decisions, for example no rebranding of the web interface, no
  update check, English documents first, and which known gaps to leave.
- **The reference.** The agent worked from the Paperless-ngx 3.4.2 source code and
  documentation. It read the Python code and ported its behaviour to Swift, module by
  module. Some texts, such as the AI prompts, are copied from Paperless-ngx word for
  word. This is why FolioZero uses the same license as Paperless-ngx.
- **The code.** The agent made the technical decisions (Swift 6, SQLite with GRDB,
  Hummingbird, Vision, WebKit, FoundationModels) and wrote the code, the tests and the
  documentation, this README included. For the larger features (share link bundles,
  mail OAuth, remote OCR, OpenID Connect), several agents worked in parallel in
  separate git worktrees. A lead session merged their commits.
- **The checks.** About 500 automated tests cover the parsers, the database, the
  search, the workflows and the HTTP API, with fake mail, OAuth and OCR servers. An
  agent drove the official Paperless-ngx 3.4.2 web interface in a browser with
  Playwright and fixed what broke. The project owner ran the binary on a headless Mac
  as a LaunchDaemon, with Apple Intelligence.
- **The notes.** [docs/DESIGN.md](docs/DESIGN.md) records the architecture and the
  technical decisions.

AI-written code can contain mistakes that the tests did not catch. Read
[Problems and shortcomings](#problems-and-shortcomings) with that in mind.

## License

Copyright (C) 2026 the FolioZero contributors

FolioZero is free software under the GNU General Public License, version 3 only
(GPL-3.0-only). See [LICENSE.md](LICENSE.md). It comes with no warranty.

FolioZero is a modified work based on Paperless-ngx 3.4.2, which is GPL-3.0, copyright
the Paperless, Paperless-ng and Paperless-ngx contributors. In November 2026 its
behaviour was ported to Swift for macOS, and some of its texts were copied.

The Paperless-ngx web interface that FolioZero downloads is a separate program under
its own GPL-3.0 license. FolioZero does not include it.

The Swift packages compiled into the binary keep their own licenses (MIT and Apache
2.0; see [Dependencies](#dependencies)). If you distribute the binary, include their
license notices with it.
