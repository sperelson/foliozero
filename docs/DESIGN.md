# FolioZero: design and roadmap

FolioZero is a macOS-native document management server. It does the job of
[Paperless-ngx](https://github.com/paperless-ngx/paperless-ngx) (reference: v3.4.2,
November 2026). It ingests documents, extracts their text (OCR where needed),
stores them in a structured archive, classifies them, and makes them searchable.

It runs on a headless Mac with macOS 27, either in the foreground as a CLI app or
as a launchd service.

## Goals

- Feature parity with Paperless-ngx, delivered in phases (see Roadmap).
- One self-contained binary, `foliozero`. No Docker, Python, Redis, Celery,
  Tika, or Gotenberg.
- Use Apple frameworks for the heavy work: Vision (OCR, barcodes), PDFKit and
  Core Graphics (PDF text, archive PDFs, page edits), ImageIO (images incl.
  HEIC), WebKit (web pages, HTML, email rendering), QuickLook (thumbnails of
  Office files), FSEvents (consume folder), launchd (service).
- A REST API that is wire-compatible with the Paperless-ngx API (v9 and v10)
  for the endpoints FolioZero implements. Existing clients (mobile apps,
  scripts, scanners that post to `/api/documents/post_document/`) then work
  unchanged.
- Web pages are first-class input: `.html`, `.webarchive`, `.webloc`/`.url`
  files, and URLs posted to the API or CLI. Paperless-ngx does not do this.

## Non-goals

- Linux or Windows support.
- Multi-host deployment (Paperless-ngx splits web server, broker and workers).
  FolioZero runs everything in one process.
- PostgreSQL or MariaDB. SQLite only.
- Bundling the Paperless-ngx Angular front end.

## Stack (decided by the builder)

| Concern | Choice |
|---|---|
| Language | Swift 6, Swift 6 language mode, SwiftPM |
| CLI | swift-argument-parser |
| Database | SQLite through GRDB (WAL, `DatabasePool`), FTS5 for full-text search |
| HTTP | Hummingbird 2 (SwiftNIO), MultipartKit for uploads |
| OCR | Vision `RecognizeTextRequest`; Tesseract as an optional engine for languages Vision lacks (for example Afrikaans) |
| Barcodes | Vision `DetectBarcodesRequest` |
| PDF | PDFKit for text, page edits and unlocking; Core Graphics for archive PDFs with an invisible text layer |
| Office files | Native OOXML/ODF text extraction (ZIPFoundation + XMLParser); AppKit `NSAttributedString` for DOC/RTF/ODT; LibreOffice `soffice` if installed for PDF conversion of every Office format |
| Web pages | WebKit `WKWebView` to render and paginate to PDF |
| Email (.eml) | Own MIME parser; rendered to PDF through WebKit |
| Thumbnails | PDFKit for PDFs, ImageIO for images, QuickLook for everything else. JPEG output (ImageIO cannot write WebP) |
| Templates | Own Jinja subset (filename formats, storage paths, workflow titles) |
| Classifier | Own one-vs-rest linear classifier over TF-IDF features (replaces scikit-learn) |
| Logging | swift-log to stderr and rotating files; `os.Logger` for unified logging |

## Process model

One process, `foliozero serve`, runs:

1. HTTP server (API, share links, later the web UI).
2. Consumer: FSEvents watcher on the consume directory, with a polling
   fallback and a stability delay before a file is picked up.
3. Task queue: an actor with N workers. Every consume, reprocess and bulk job
   is a task row in the database, so `/api/tasks/` reports progress.
4. Scheduler: periodic jobs (mail fetch, classifier training, sanity check,
   empty trash, scheduled workflows, index optimise).

WebKit and some AppKit APIs need a main run loop. The binary drives
`RunLoop.main` on the main thread and runs everything else in Swift tasks.

## Data layout

`FOLIOZERO_HOME` (default `~/Library/Application Support/FolioZero`) holds:

```
foliozero.conf          KEY=VALUE settings (optional)
data/foliozero.sqlite   database (+ -wal, -shm)
data/classifier.json    trained classifier
data/log/               rotating log files
media/documents/originals/    original files, named by filename format
media/documents/archive/      archive PDFs with text layer
media/documents/thumbnails/   0000123.jpg
consume/                consume directory
scratch/                working files during processing
export/                 default export target
```

Each directory can be overridden (`FOLIOZERO_DATA_DIR`, `FOLIOZERO_MEDIA_ROOT`,
`FOLIOZERO_CONSUMPTION_DIR`, `FOLIOZERO_SCRATCH_DIR`).

## Configuration

Settings come from, in order of precedence: CLI flags, environment variables,
`foliozero.conf`, database application config (API `/api/config/`), defaults.

Names mirror Paperless-ngx with the prefix `FOLIOZERO_`. FolioZero also reads
the `PAPERLESS_` name of each setting, so an existing `paperless.conf` can be
reused. Settings that only exist because of Docker, Redis, Celery, Tika or
Gotenberg are dropped.

## Ingest pipeline

Order matches Paperless-ngx:

1. Source: consume folder, API upload, CLI, mail, URL capture.
2. Pre-checks: file type detection (magic bytes + UTType), checksum, duplicate
   check (`CONSUMER_DELETE_DUPLICATES`).
3. Workflows with trigger "Consumption Started".
4. Pre-consume script.
5. Barcodes: separator pages, ASN, tag barcodes, split into several documents.
   Double-sided collation.
6. Parse: text extraction, OCR (`OCR_MODE` auto | redo | force | off), archive
   PDF (`ARCHIVE_FILE_GENERATION` auto | always | never), thumbnail, page count,
   date detection.
7. Matching: tags, correspondent, document type, storage path (none, any, all,
   exact, regex, fuzzy, auto).
8. Store files under the filename format / storage path; write DB rows; index.
9. Workflows with trigger "Document Added".
10. Post-consume script, notifications.

### Supported input

| Kind | Types | Handler |
|---|---|---|
| PDF | `application/pdf` (incl. encrypted, with workflow password removal) | PDFKit + Vision |
| Images | JPEG, PNG, TIFF (multi-page), GIF, BMP, WebP, HEIC/HEIF | ImageIO + Vision |
| Text | `text/plain`, `text/csv`, `application/csv`, Markdown | direct |
| Office | doc, docx, xls, xlsx, ppt, pptx, ppsx, odt, ods, odp, odg, rtf | native extraction; LibreOffice for PDF |
| Email | `message/rfc822` (.eml) | own MIME parser + WebKit |
| Web | `.html`, `.htm`, `.webarchive`, `.webloc`, `.url`, URLs | WebKit |

## Search

SQLite FTS5 table, tokenizer `unicode61 remove_diacritics 2` (accent
insensitive), optional Porter stemming. The Paperless-ngx query language
(`AND`/`OR`/`NOT`, phrases, `field:value`, wildcards, numeric and date ranges,
relative dates) is parsed into an AST and compiled to SQL. FTS5 `bm25` gives
the score and `snippet()` gives highlights. `more_like_id` uses the top TF-IDF
terms of the source document.

## Security

- Passwords: PBKDF2-SHA256 in Django format
  (`pbkdf2_sha256$<iter>$<salt>$<hash>`), so Paperless-ngx user rows can be
  imported.
- API auth: Basic, Token (`Authorization: Token ...`), session cookie with
  CSRF for browsers.
- Global permissions use Paperless-ngx codenames (`view_document`, ...).
  Object permissions: owner, view and change for users and groups.
- Webhooks and mail hosts respect the "no internal hosts" settings.

## Service mode

`foliozero service install` writes a launchd plist and loads it.

- Default: LaunchAgent in the user's GUI domain. Vision, WebKit and QuickLook
  work reliably there. On a headless Mac, enable automatic login for that user.
- `--system`: LaunchDaemon with `UserName`, starts at boot without a login.
  WebKit page rendering may not work in this context; FolioZero falls back to
  text extraction without a rendered archive PDF and logs a warning.

Other subcommands: `uninstall`, `start`, `stop`, `restart`, `status`, `logs`.

## Roadmap

| Phase | Scope |
|---|---|
| 1. Foundation | Package layout, config, data dirs, DB schema and migrations, models, logging, CLI skeleton |
| 2. Ingest | Type detection, PDF/image/text parsers, Vision OCR, archive PDF, thumbnails, dates, checksum and duplicates, matching (non-auto), filename format and storage, FTS index, `consume`, `list`, `show`, `search` CLI |
| 3. Server | HTTP server, users and auth, core REST API (documents, tags, correspondents, document types, storage paths, tasks, search, post_document, download/preview/thumb), consume-folder watcher, task queue, scheduler, `serve` |
| 4. Service | launchd install/uninstall/status/logs, log rotation, graceful shutdown |
| 5. More inputs | Office, HTML/webarchive/URL capture, .eml, LibreOffice integration, Tesseract engine |
| 6. Organisation | Custom fields, notes, saved views, share links, trash, audit history, object permissions, bulk edit, PDF edits, document versions |
| 7. Automation | Barcodes, double-sided collation, workflows (all triggers and actions), Jinja templates in storage paths and titles, auto classifier, pre/post consume scripts |
| 8. Mail | IMAP accounts and rules, processed-mail tracking, SMTP sending (email workflow action, share by email) |
| 9. Admin | Exporter/importer (Paperless-compatible manifest), sanity checker, renamer, retagger, thumbnail and archive regeneration, Paperless-ngx database import |
| 10. Web UI | Browser UI served by `foliozero serve` |
| Later | OIDC, 2FA, AI suggestions and chat, remote OCR |

### Status (2026-11-07)

| Phase | State |
|---|---|
| 1. Foundation | Done |
| 2. Ingest | Done: PDF, images, text; Vision and Tesseract OCR; archive PDFs; thumbnails; dates; matching; file naming; FTS search; CLI |
| 3. Server | Done: task queue, folder watcher (FSEvents and polling), scheduler, REST API (Paperless-ngx API v9 and v10), WebSocket status |
| 4. Service | Done: `foliozero service install/uninstall/start/stop/restart/status/logs` |
| 5. More inputs | Done: web pages (WebKit, paginated archive PDF), URL capture (`add-url`), `.webloc`/`.url`, `.eml`, Office (native text; LibreOffice optional for archives) |
| 6. Organisation | Done: custom fields, notes, trash, audit, permissions, versions, PDF operations, bulk download, email, share links and share link bundles |
| 7. Automation | Done: workflows (all triggers; assignment, removal, webhook, email, trash, password list), auto classifier, scripts, barcodes (split, ASN, tags, stored values), double-sided collation |
| 8. Mail | Done: IMAP client, mail rules, SMTP, Gmail and Outlook OAuth (XOAUTH2, token refresh) |
| 9. Admin | Done: sanity check, renamer, retagger, reprocess, thumbnails, Paperless-ngx exporter and importer |
| 10. Web UI | Done: serves the official Paperless-ngx frontend from a release build (`FOLIOZERO_FRONTEND_DIR`), not bundled; browser-tested with v3.4.2 |
| Later | Done: TOTP two-factor login, auto-login, OIDC sign-in, AI suggestions, LLM index, similar documents and chat, remote OCR (Azure AI Document Intelligence) |

## Risks

- WebKit inside a LaunchDaemon. Mitigation: LaunchAgent is the default.
- Archive PDFs are PDF with a text layer, not validated PDF/A. If Ghostscript
  is installed, `FOLIOZERO_OCR_OUTPUT_TYPE=pdfa` converts with `gs`.
- Vision lacks some languages. Tesseract is the fallback engine.
- Legacy binary `.xls` and `.ppt` need LibreOffice for text and PDF.
