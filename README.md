# ROM Organizer

Organize your Nintendo Switch ROM library on Android. Import zips, auto-title
them from TheGamesDB, extract into clean per-game folders with updates
separated, and reclaim space by deleting fully-extracted zips.

## Features

- **Import pipeline** — browse to a `.zip`, `.tar`, `.gz`, `.bz2`, `.xz` archive
  **or an already-extracted `.nsp` / `.xci` ROM**, auto-resolve the real game
  title from TheGamesDB (editable), and organize it into a per-game folder.
  The import view starts in `Download/` and cannot browse above it.
- **Auto-import** — tap the ✨ button to recursively scan the current folder
  and import every Switch ROM and archive it finds, auto-titling each one. The
  organized library itself is excluded from scans so files already imported are
  not re-imported.
- **Switch-ROM validation** — before extracting an archive, the app checks its
  contents actually contain Switch ROM files (`.nsp`/`.xci`/`.nsz`/`.xcz`/
  `.nca`). If not, it tells you to provide a Switch ROM archive only — nothing
  is extracted.
- **Clean layout** — each game gets its own folder, with update files in an
  `update/` subfolder:
  ```
  /storage/emulated/0/Download/ROM Manager/ROMs/
    The Legend of Zelda - Breath of the Wild/
      The.Legend.of.Zelda.Breath.of.the.Wild.nsp
      update/
        ...Update.v1.6.0.nsp
  ```
- **Archives are extracted; loose ROMs are moved.** An archive is extracted
  and, once verified fully extracted, you're offered to delete it to reclaim
  space. An already-extracted `.nsp`/`.xci` is moved into the library (no copy,
  no leftover).
- **Downloads-scoped storage** — organized games live in
  `Download/ROM Manager/ROMs/`, while app-managed content lives in
  `Download/ROM Manager/Content/`. On the first launch after upgrading, the
  app safely moves data from the old `/ROMs/Switch`, `/ROMs`, `/ROM`, and
  `/Content` locations (including `Download/ROM` and `Download/Content`).
  Existing destination files are never overwritten.
- **Library view** — grid of your games with cover art (fetched from
  TheGamesDB and cached locally), an "has update" badge, and a detail view
  listing base + update files.
- **Recognized formats** — `.nsp`, `.xci`, `.nsz`, `.xcz`, `.nca`.

> **Note on archives:** supported archive formats are `.zip`, `.tar`, `.gz`,
> `.tgz`, `.bz2`, `.tbz2`, `.xz`, `.txz`. **7z and rar are not decoded in-app**
> — the underlying `archive` library has no decoders for them. The app still
> *sees* `.7z`/`.rar` files and prompts you to extract them with your device's
> built-in file manager, then import the extracted `.nsp`/`.xci`.

## Requirements

- Android device with **all-files access** granted (the app prompts on first
  launch). Direct filesystem access is needed for large moves, extraction, and
  the one-time legacy migration; the app's browser remains confined to
  Downloads. This sideloaded tool is **not** on the Play Store.
- A free **TheGamesDB API key** for title + cover-art lookup. Create an account
  at [thegamesdb.net](https://thegamesdb.net), then grab your key at
  [api.thegamesdb.net/key.php](https://api.thegamesdb.net/key.php). Paste it in
  the app's **Settings** screen. The key is stored only on your device.

## Install

Download the latest `app-release.apk` from the
[Releases](https://github.com/rakshithn92/rom-organizer/releases) page and
sideload it. You may need to allow "install from unknown sources" for your
browser/file manager.

## Build from source

```bash
flutter pub get
flutter analyze
flutter test
flutter build apk --release
# APK at build/app/outputs/flutter-apk/app-release.apk
```

## How it works

- **Zip classification** — entries are classified as base / update / dlc by
  filename markers and `update/` folder paths.
- **Title parsing** — region tags (`[USA]`), version tags (`v1.6.0`), and
  title-IDs (`0100...`) are stripped from filenames to build a clean search
  query.
- **Update matching** — update title IDs are normalized to their base-game IDs.
  Existing base filenames are inspected as a fallback for libraries created by
  older app versions, and the discovered relationship is cached in SQLite. If
  a loose update has no usable ID, manual import asks which existing game it
  belongs to instead of guessing from a potentially ambiguous title prefix.
- **Metadata** — TheGamesDB `ByGameName` is queried for the Switch platform;
  the resolved title and boxart are used for the folder name and cover.
- **Filesystem safety** — game titles are validated as a single folder name,
  imports never overwrite an existing ROM, and move errors retain the completed
  copy when the source cannot be removed.
- **Responsive maintenance** — recursive scans, ROM imports, archive decoding,
  merges, renames, and update cleanup run outside Flutter's UI isolate.

## Project structure

The Dart code is split by responsibility so storage or matching bugs can be
fixed without changing unrelated UI code:

- `lib/config/` — shared storage paths and supported file formats.
- `lib/models/` — data returned between scanners, importers, and screens.
- `lib/services/` — parsing, matching, metadata, persistence, and filesystem
  operations.
- `lib/screens/` — Flutter presentation and user-flow orchestration.
- `test/` — unit and widget regression coverage.

## Privacy

- All ROM files stay on your device. Nothing is uploaded.
- The only network calls are to TheGamesDB for title/cover lookup.
- Your API key is stored locally in the app's SQLite database.

## License

[MIT](LICENSE)
