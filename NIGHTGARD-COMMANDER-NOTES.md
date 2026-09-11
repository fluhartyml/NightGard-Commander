# NightGard Commander — what we do in the app, and how to do it from the command line

**Started 2026-09-11 at Michael's instruction:** *"you also need to take notes of what we are doing
in nightgard commander so you can do the same thing via cli nightgard commander."*

**The rule this file exists to enforce: anything the interface can do, the CLI gets a verb for, and
both read and write the SAME `UserDefaults` — never a second store.** A setting that only the
interface can reach is a setting that cannot be scripted, and a second store is two answers to one
question.

The binary is the app bundle itself:

```
"/Users/michaelfluharty/Library/Developer/Xcode/DerivedData/NightGard_Commander-davjfllweggsxmhasaqiqyqwedpz/Build/Products/Release/NightGard Commander.app/Contents/MacOS/NightGard Commander"
```

Passing a recognised verb runs the job headlessly and exits before any window opens. Anything else
launches the normal interface. → `CLIRunner.swift`

---

## The interface, as it actually is

**Two panes**, each an independent file browser with its own path. The action row along the bottom
is Command-3 through Command-9: View, Edit, Copy, Move, New, Delete, Rename.

**Most media work is on the right-click menu, not the action row.** Right-clicking a **folder**
gives Scan for Media and, as of 2026-09-11, Designate as Target Music Library.

---

## 1. Designate the target music library parent directory

**His ask, 2026-09-11:** *"i want to select a folder and right click to designate as the target
music library parent directory. the designation should also be saved in nightgard commander >
settings."*

| | |
|---|---|
| **In the app** | right-click a folder → **Designate as Target Music Library**. Right-clicking the folder that is already designated offers **Clear Target Music Library** instead. |
| **In Settings** | Command-comma → **Music Library** section. Shows the current target, a **Choose Folder** picker and **Clear**. Settings changes commit on **Save Settings**; the right-click item writes immediately. |
| **From the CLI** | `--set-music-library <folder>` to set, `--music-library` to read |
| **Stored as** | `UserDefaults` key `musicLibraryTargetPath`, a plain path |

```sh
APP="/Users/michaelfluharty/Library/Developer/Xcode/DerivedData/NightGard_Commander-davjfllweggsxmhasaqiqyqwedpz/Build/Products/Release/NightGard Commander.app/Contents/MacOS/NightGard Commander"

"$APP" --set-music-library "/Volumes/Raid_4x4/Media/Music/<the flat music folder>"
"$APP" --music-library
```

**Exit codes on `--music-library` are the useful part:** `0` designated and reachable, `1` nothing
designated, `2` designated but **not reachable** — which is the normal state when the array is
unmounted. A script should check it rather than assume the folder is there.

**Why a plain path and not a security-scoped bookmark:** the app is **not sandboxed** — verified by
reading the built binary's entitlements, which carry no `com.apple.security.app-sandbox` key. A
saved path therefore still opens after a relaunch.

**Paths are standardised on both sides** (`standardizedFileURL`) because the right-click menu decides
whether to show Designate or Clear by comparing strings. Without that, `/Volumes/Raid_4x4/Media/`
and `/Volumes/Raid_4x4/Media` would look like two different folders.

---

## 2. Consolidate music into one folder — Scan for Media

| | |
|---|---|
| **In the app** | right-click a **folder** → **Scan for Media...** |
| **Options** | Add to Playlist · Copy to Other Pane · Move to Other Pane, and an organisation choice: **Flatten (all in one folder)**, Folders by Extension, Folders by Media Type |
| **Destination** | the other pane's path, changeable in the dialog |
| **From the CLI** | **`--scan <folder>` only LISTS what it finds.** There is no CLI verb that performs the copy or move. |

**⛔ THE COLLISION HAZARD, and it matters for the 41,700-file consolidation.** When flattening, a
name collision is resolved by suffixing `-2`, `-3`, and so on — `getUniqueFileURL` in
`ScanForMediaDialog.swift`. **It never compares the two files.** Pointed at four overlapping
libraries, that converts duplicates into thousands of separately-named keepers, which is the
opposite of consolidating. → Skills Lab: *Compare on collision; never suffix*

**Open gap:** Copy/Move has no CLI verb. Until it does, the consolidation itself cannot be scripted
through this app.

---

## 3. Normalize filenames

**The format is `Artist - Title - Album`**, with `/` and `:` replaced by `-`. It is built from an
ordered list of blocks, editable in Settings → Filename Format → Change Format, stored under the
`shazamFormatBlocks` key. **Michael has never changed it**, so the built-in default applies.
→ `ShazamSettings.formatBlocks`, `FilenameFormatBuilder.swift`

| | |
|---|---|
| **In the app** | Settings → Database → **Reformat All** — renames everything already in the scanned database using the current format, no network |
| **From the CLI** | `--reformat` |

---

## 4. Identify files that have no usable name

**⛔ READ THIS BEFORE PLANNING ANY IDENTIFICATION RUN. Commander cannot identify a file cold.**

`processWithiTunesAPI` has an explicit `// No Apple Music ID - skip` branch: it only refreshes files
that **already carry an Apple Music ID from a previous Shazam pass**. A library that has never been
through one comes back 100% skipped. That is why pointing it at the array produced nothing on
2026-09-11. → `ShazamService.swift`

| Verb | What it actually does |
|---|---|
| `--scan <folder>` | lists media files; populates nothing the other verbs read |
| `--shazam <folder>` | fingerprints audio. **Needs the ShazamKit entitlement, which is enabled on the App ID at developer.apple.com — an ad-hoc signed build fails with error 202.** |
| `--itunes <folder>` | refreshes metadata for files that already have an Apple Music ID. Cold files are skipped. |
| `--detect <file>` | identifies one file and prints the result |
| `--reformat` | renames from the database, no network |

**The ladder Michael described** — scan, build a partial name from the filename, refine it against
iTunes Search behind a trust gate, and use Shazam **only as a last-resort tiebreaker** so the
service is not flooded — **is in NightGard Library Commander, not this app.** It was built there on
19 April and run across 11,917 tracks. In his words: *"it was all set up so it didnt flood shazam
and cause us not to have shazam for another 24 hours."*

**And Library Commander cannot be pointed at the array.** It drives **Music.app over AppleScript**,
track by persistent ID (`LibraryService.swift`). It has no path to loose files on a drive.

**So the split is:** Commander consolidates, Library Commander identifies, and **neither one
identifies loose files on a disk cold.** That gap is the real blocker on normalising the array.

---

## 5. Build number

**Installed 2026-09-11.** This repo had no build-number machinery at all, so every build it ever
produced called itself `1.0 (1)` — the exact condition that cost a full day on Shell Citadel.

- `Scripts/stamp-build.sh` writes `CURRENT_PROJECT_VERSION = git rev-list --count HEAD`
- `Scripts/install-hooks.sh` installs post-commit, post-checkout and post-merge.
  **Run it once per clone — git never copies hooks.**
- `BuildStamp.swift` carries the commit, branch and build time; the number is read from the bundle
- **Shown in the app:** menu → About NightGard Commander
- **From the CLI:** `--version`

→ `Workshop/BUILD-NUMBER-STANDARD.md` in the apartment

---

## Still missing from the CLI

Written down so the gap is visible rather than rediscovered.

1. **Copy/Move with flatten** — the consolidation itself. Interface only.
2. **Cold identification** — no verb, because no code path does it in this app.
3. **Collision comparison** — nothing anywhere compares two colliding files; it only suffixes.
