# ROM Organizer

Organize your Nintendo Switch ROM library on Android. Import zips, auto-title
them from TheGamesDB, extract into clean per-game folders with updates
separated, and reclaim space by deleting fully-extracted zips.

## Features

- **Import pipeline** — browse to a `.zip`, `.tar`, `.gz`, `.bz2`, `.xz` archive
  **or an already-extracted `.nsp` / `.xci` ROM**, auto-resolve the real game
  title from TheGamesDB (editable), and organize it into a per-game folder.
  The import view starts in `Download/` by default.
- **Auto-import** — tap the ✨ button to recursively scan the current folder
  and import every Switch ROM and archive it finds, auto-titling each one.
- **Switch-ROM validation** — before extracting an archive, the app checks its
  contents actually contain Switch ROM files (`.nsp`/`.xci`/`.nsz`/`.xcz`/
  `.nca`). If not, it tells you to provide a Switch ROM archive only — nothing
  is extracted.
- **Clean layout** — each game gets its own folder, with update files in an
  `update/` subfolder:
  ```
  /storage/emulated/0/ROMs/Switch/
    The Legend of Zelda - Breath of the Wild/
      The.Legend.of.Zelda.Breath.of.the.Wild.nsp
      update/
        ...Update.v1.6.0.nsp
  ```
- **Archives are extracted; loose ROMs are moved.** An archive is extracted
  and, once verified fully extracted, you're offered to delete it to reclaim
  space. An already-extracted `.nsp`/`.xci` is moved into the library (no copy,
  no leftover).
- **Library view** — grid of your games with cover art (fetched from
  TheGamesDB and cached locally), an "has update" badge, and a detail view
  listing base + update files.
- **Emulator integration** — open a game directly in an installed Switch
  emulator (Yuzu, Sudachi, etc.) with the play button on the game's detail
  screen. Android shows an "open with" chooser listing your emulators.
- **Recognized formats** — `.nsp`, `.xci`, `.nsz`, `.xcz`, `.nca`.

> **Note on archives:** supported archive formats are `.zip`, `.tar`, `.gz`,
> `.tgz`, `.bz2`, `.tbz2`, `.xz`, `.txz`. **7z and rar are not decoded in-app**
> — the underlying `archive` library has no decoders for them. The app still
> *sees* `.7z`/`.rar` files and prompts you to extract them with your device's
> built-in file manager, then import the extracted `.nsp`/`.xci`.

## Requirements

- Android device with **all-files access** granted (the app prompts on first
  launch). This is a sideloaded tool — it is **not** on the Play Store.
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
- **Metadata** — TheGamesDB `ByGameName` is queried for the Switch platform;
  the resolved title and boxart are used for the folder name and cover.

## Privacy

- All ROM files stay on your device. Nothing is uploaded.
- The only network calls are to TheGamesDB for title/cover lookup.
- Your API key is stored locally in the app's SQLite database.

## License

[MIT](LICENSE)
