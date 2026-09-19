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

---

## ⬜ PLANNED — Nuclear Mode: left-handed toggle (his, 2026-09-16 22:3x). NOT BUILT.

**How Nuclear Mode is laid out today, in his words:** *"its set up to sort from th right window with
multiple files to the left with multple folder pigeon holes."* The RIGHT pane holds the files being
sorted; the LEFT pane holds the destination folders ("pigeon holes"). → moves the current file across
and plays the next, ↓ next, ↑ previous, ← undoes the last move (`FileBrowserPanel.swift`, the
compass rose around the nuclear glyph).

**The ask:** *"we will need to add a left handed toggle to inverse."* A toggle that mirrors it —
files on the LEFT, pigeon holes on the RIGHT — with the arrow meanings flipped to match
(← moves + plays next, → undoes).

⬜ Open, ask him before building: where the toggle lives (Settings, the compass rose, or both), and
whether it also needs a CLI verb — the rule at the top of this file says anything the interface can
do gets one, stored in the same `UserDefaults`.

---

## 🔀 MOVE / COPY COLLISIONS — his spec, 2026-09-18 07:3x–07:5x. NOT BUILT YET.

**Found first:** multi-select Move (⌘6) exists, but `moveSelectedToOtherPane()` calls
`moveItem` straight at the destination — a same-named folder there makes it **throw and print to
the console only. Nothing moves, nothing tells him.** Copy (⌘5) silently suffixes instead.

**Terms — SIDE-AGNOSTIC, his rule: *"DO NOT USE LEFT OR RIGHT."*** The **source** tab holds what is
moving; the **target** tab receives it.

**His framing:** *"on move it is destructive so rules are needed because copy isnt AS destructive."*
Model is DOS / Finder.

1. **Folder collision** — source `Parent` onto a target that already has `Parent` → popup:
   **are you sure?** then **Merge** or **Replace**.
   - **Replace** = the target's `Parent` and its whole tree are removed and the source's `Parent`
     takes its place (Finder's Replace behaves this way).
   - **Merge** = combine the two, and **ask the same question again for every same-named
     sub-folder**, all the way down.
2. **File collision** inside a merge → popup: **Replace** · **Skip** · **Keep Both**
   (Keep Both adds a number to the incoming one — *"keeping both adds a number"*).
3. **"Apply to all"** checkbox on the popups — *"yes add apply to all."*

⬜ **Unasked:** whether Apply to all on the folder popup is wanted too (assumed yes, confirm).
⬜ **First real use:** five folders from `Raid_4x4/Backup` to `Cold Storage 12TB/backups`. The
target's `2025 OCT 19 Photo Library` is a **partial copy** (750 files / 191 KB, database folder only,
written 07:25 09-18) of the source's complete one (32,808 files / 6.2 GB).
4. **Multiple source folders at once** — *"i also want to be able to select multiple originating
   folders"* (09-18). Each selected folder runs through the same collision rules.
5. **His idea: port Midnight Commander's code** — *"if you copy midnight commanders code and merge
   with NG commander most issues will fix themselves."* MC is GPL v3+ (compatible with his GPL);
   it is **C** (ncurses/GLib), Commander is **Swift/SwiftUI**. See the discussion before deciding.

### ✅ BUILT on `file-ops` (2026-09-18) — plan sections 1–3 and 5
- `FileOperationEngine.swift` / `Models` / `Controller` / `Views`; MoveGuard = live libraries only.
- Wired: command bar Copy ⌘5 / Move ⌘6, hidden ⌘C / ⌘X, right-click Copy/Move (one or many).
  **Edit › Undo Last Move…** reads the newest move log (`~/Library/Application Support/NightGard
  Commander/Operations/`).
- ⚠️ **NOT routed through the engine, on purpose:** the **M key** and **nuclear mode** keep their
  own single-file DJ-curation move (`moveToOtherPane(item:)`), which already asks on a duplicate.
  Route them through the engine only if he asks.
- Self-tested headless on the internal drive, Raid_4x4 (HFS+) and Cold Storage (SMB); the
  popups were rendered and read. **He has not run it yet.**
- ✅ **Plan section 4 BUILT (build 58):** preview button in each pane's header (remembered per pane);
  `PanePreview.swift` — poster art → frame a few seconds in → album art → Quick Look; folders show
  count, size (capped at 4 s: "at least this") and thumbnails. Player minimizes to a bar under the
  preview and maximizes over it; video opens big, audio opens as the bar; Escape shrinks it.
  ⚠️ **One change from plan 4.10:** Space was NOT made "maximize" — Space already means play/pause
  in the pane, and taking it over would break that. Click the bar or its ⤢ button instead. Ask him.
  ⚠️ The video still is verified to be the right frame at the right size; how it LOOKS in the real
  window is unverified — the test snapshots could not draw large images reliably.

## 🗜️ FLATTEN + EXTRACT FROM LIBRARY — his spec, 2026-09-18 ~12:3x. NOT BUILT.

**Flatten.** Source pane: a folder or drive. Target pane: a folder. Every file anywhere under the
source goes straight into the target — no subfolders. Copy or Move.
- **Same-name files: Skip or Keep Both**, with **Apply to all**. His: *"if not checked apply to all
  would make this so you could go folder by folder."* (No Replace offered in Flatten.)
- **Libraries (`.photoslibrary` etc.) are copied/moved WHOLE, like a single file** — never opened up.
- ENG: hidden files (`.DS_Store`) skipped.
- ✅ **After a Flatten Move: ASK the user — Leave (default) or Remove the now-empty folders.** His: *"leave the folders but ask the user what to do."* Only fully empty folders are offered.

**Extract from library** — a second workflow. Source pane: select a library ("deflate"). Target pane:
a folder. **Copy = the library container is preserved. Move = the container is emptied.**
- ENG ⚠️: inside a Photos library the originals carry **UUID file names**; the real names, dates,
  albums and edits live in the library's database, not the files. Extracted files will not have the
  names he sees in Photos unless the app reads them from the database.
- ENG: Move-extract from a **LIVE** library stays blocked (MoveGuard) — it would break Photos.

## ✅ BUILT 2026-09-18 — plan section 8: long transfers you can walk away from
- **The whole target folder tree is made first** (phase "Making the folders first"), then files go
  folder by folder — **a folder's own files before its subfolders**, each in Finder's order.
  Folders under something a Replace will throw away are NOT made early (they would go in the Trash with it).
- **Resume = run the same operation again** → Merge + Apply to all → only what is missing is sent.
- **Progress by folder:** "Folder 12 of 340 — name — file 88 of 412".
- **Time left from two measured rates** (per-file overhead + data rate). The old bytes-only figure said
  174,121 h / 449 h on 536,716 tiny files.
- **Copy remembers what it already verified** (`~/Library/Application Support/NightGard Commander/Verified copies.tsv`,
  keyed by target path; valid only while source path, sizes and dates are unchanged) → a re-run does not
  re-read the network drive. A touched file is compared byte for byte again.
- **Hidden `.ngc-partial-` files left by a cut-off run are cleared** and the file is sent again; summary says so.
- Summary headline no longer cut off ("was lef…").
- 6.3 answered from the code: Apply to all appears only when more collisions of that kind are coming.
- Self-test: all pass, internal → Raid_4x4 and internal → Cold Storage (SMB).

## ✅ BUILT 2026-09-18 — plan 6.2 and all of section 7 (7.1–7.11)
- **6.2** — the folder question shows what each side holds ("12 items · 78 KB · more" vs "1 item · 7 bytes · fewer").
- **Operations menu:** Flatten Copy… ⌥⌘5 · Flatten Move… ⌥⌘6 · Extract from Photos Library… ⌥⌘E (source pane → target pane).
- **Flatten (7.1–7.5):** every file under the selection into the target folder, no subfolders. Same-name files
  (from the target OR from two source folders) ask **Keep Both / Skip** + Apply to all — nothing is ever replaced.
  Libraries/packages go whole. Hidden files stay (summary says how many). After a Flatten **Move**: asks
  **Leave Them (default) / Remove Them** for the emptied folders; a folder still holding anything is never offered.
- **Extract (7.6–7.11):** reads `database/Photos.sqlite` from a COPY (never opens the library's own file) →
  real names (ZADDITIONALASSETATTRIBUTES.ZORIGINALFILENAME) and date taken (ZASSET.ZDATECREATED) on each file.
  Live Photo video beside it as `<name>.mov`. Skips Recently Deleted and iCloud-only originals, and says so.
  **Original / JPEG (quality slider, default 90%) / PNG / TIFF** via ImageIO — metadata carried across.
  Copy leaves the library alone. Move empties it: an unconverted original is moved (Undo puts it back under its
  code name); a converted one's original goes to the Trash after the new file is read back. A LIVE library is
  always copied (MoveGuard). Works on a .photoslibrary or a plain-folder backup of one. "Masters" (pre-10.15) refused.
- **Fixed, found by the self-test:** 8.5's verified record now includes both files' inodes — a file deleted and
  re-created with the same size and date had matched its old record and been called identical unread.
- Self-test: ALL PASSED twice each on Raid_4x4 and Cold Storage (SMB); UI harness drew every new popup.
- Still open (his call): 4.10 — Space stays play/pause; the bar is clicked to grow the player.

## ✅ BUILT 2026-09-18 — build 61: time left he can believe
His report on 60: *"it fluctuates days 1 hour 50 minutes to 22 minutes"* (and 357 h shown on a ~2 h job).
- Data speed is learned only from LARGE reads (≥ 1 MiB); tiny files' time is per-file overhead.
- No large read timed yet → "estimating time left…" instead of a guess.
- Shown figure re-computed at most every 5 s, counted down by elapsed time, eased 25% toward each reading.
- Rounded: "about 1 h 50 m left" (5-min steps past an hour), whole minutes under, "under a minute left".
- Self-test on Cold Storage: 159 s job, estimates 324 → 319 → … → 50, never a >3× jump.

## ✅ BUILT 2026-09-18 ~19:2x (after his Move finished) — his spec, 18:1x: refresh + parallel jobs
**1. Pane refresh.** A pane kept listing files a running Move had already taken (derivatives/0: 731
stale items, preview blank). Panes must refresh as an operation empties or fills the folder they show.

**2. More than one operation from the same two panes.** His words: *"i want to be able to manipulate
more folders between using the same two panes without leaving them on the same two disk locations."*
⌘N (a second window) was ruled out: *"command n is not realistic ( not intuitive)"*.
- **His first choice — PARALLEL:** *"if it would open a new moving or copying bar in parallel would be
  best"* → Copy/Move stay enabled while something runs; each job gets its own progress bar; the panes
  are free to navigate elsewhere.
- **Acceptable fallback — QUEUE**, on his condition: *"as long as you could X the cueued up task before
  it started without breaking the queue."*
- Note for the build: parallel jobs share one network link to Cold Storage — each runs slower; the
  time-left estimate must be per job. Two jobs touching the same item must be refused, not raced.

**How it was built:**
- `FileOperationJob` = one copy/move: its engine, progress, Pause/Cancel, pending question. One bar each
  (`ForEach(fileOps.jobs)`); Copy/Move/Flatten/Extract are no longer disabled while something runs.
- The controller shows questions ONE AT A TIME, in the order asked, and routes each answer to the job that
  asked. Cancelling a job takes its waiting question out of line; the others keep their places.
- Refusal, not race: a job whose sources or destinations overlap a running job's (same path, inside, or
  containing — case-insensitive) is not started; a summary says so in a sentence. Undo waits for all jobs.
- Selection: a finished Move takes only ITS items out of the selection (it used to clear everything).
- Refresh: `FileSystemService.refreshInPlace()` reads off the main thread, keeps unchanged items' IDs (so
  the selection survives), does nothing if nothing changed, and if the folder is gone steps UP to the
  nearest one left — `loadFiles` jumped all the way home (his right pane landed in ~ at 19:12).
  While jobs run, a pane whose folder overlaps a job's footprint is refreshed every 3 s.
- Tests (scratch harness driving the real controller): parallel jobs with a question each answered to the
  right job, overlap refusals, cancel-in-line, refresh ID-keeping and step-up — ALL PASSED on the Mac
  drive, Raid_4x4 and Cold Storage (SMB). ⚠️ The new bars were NOT looked at on screen yet.

## ✅ BUILT 2026-09-18 ~21:3x — build 64: From/To, time left (third fault), Show in Finder
- **Summary says what moved and where:** his question with three jobs running — *"its done moving but
  what folder to what folder was moved?"* The popup now has **From** / **To** lines, drive first
  ("Raid_4x4 › Users › …"), so same-named folders on two drives cannot be confused.
- **Time left, third fault:** build 63 said *"about 4d 11h 25m"* on a 10.79 GB move at 6.5 MB/s (~45 min).
  Only READS were timed as data; a big file's flush, read-back open and delete were charged as per-file
  overhead, and the library's first files were multi-GB Spotlight indexes. Now each file is timed WHOLE
  (pauses removed): large files teach the data rate, small files the per-file cost; Undo keeps wall-clock.
  ⚠️ Verified only on local drives (engine suite ALL PASSED Mac→Raid, new test 28 big-then-tiny). The
  network run was STOPPED at his "i think i may be pushing the limits on my mac" — four jobs were sharing
  the link. **Rerun test 28 against Cold Storage when the link is quiet** (old engine vs new).
- **Show in Finder on every right-click** — his words: *"i also want a show in finder right click for
  everything"*: file rows (one or many), a pane's empty space (the folder itself), empty-folder view,
  playlist rows, each progress bar (source / destination), the summary's From, To and item rows.
  A path a Move already took is shown by its nearest folder that still exists (`FinderReveal`).

## ⬜ PLANNED / ASKED — his, 2026-09-18 21:1x–21:3x. NOT BUILT.
1. **Lock the folders a job is using** — *"i want a folder that if i am moving or copying to temporarily
   lock so i dont accidentally delete it while manipulating files in the folder or sub folder"*.
   Plan: while a job runs, Commander refuses Delete / Rename / Move of anything overlapping its footprint
   (the folder, anything above it, and what it is writing), with a plain sentence; other files inside stay
   free. ⚠️ Commander cannot stop Finder — say so. (Finder's own lock flag would block the job's writes.)
2. **Delete goes nowhere recoverable** — he asked *"can it delete to the trashcan? im just curious not
   directing"*. Answer given: NO — `FileSystemService.deleteItem` is `removeItem`, immediate, and no
   confirm was found. Cold Storage (SMB) has no Trash regardless. **Not directed; ask before changing.**
3. **A governor** — *"is there a govoner or regulator to keep the mac stable?"* None exists; four jobs ran
   at once. Offered: at most 2 running, the rest wait in line, each with an X (his queue condition).
   **His refinement, 21:4x:** he paused all four and resumed them one at a time — *"this pause is cool
   because i can pause them all and let them resume one at a time"* — and then: ***"it needs to say
   system unstable; paused untill system becomes stable again or similar"***.
   So the governor PAUSES jobs itself (the existing Pause, not a new mechanism) and the bar says why, e.g.
   "System unstable — paused until it is stable again", resuming them one at a time when it clears.
   ⬜ "Unstable" still to be defined with him — candidates macOS reports directly: memory pressure,
   `ProcessInfo.thermalState` (serious/critical), low battery off power, a drive nearly full, a network
   drive that stopped answering. A pause HE made must never be auto-resumed.
   **His further spec, 21:5x:** ***"i think we also could use that iser feedback bar at the bottom that
   tells the user comprehensively what tasks are running in the commander the pause warning should be on
   each status bar and the user can override and resumw at their own rish"***
   - **An overall feedback bar at the bottom** — every task Commander is running, in one place (e.g.
     "4 tasks — 2 moving, 2 paused: system unstable — 16 GB of 91 GB").
   - **The pause warning on EACH job's own bar**, not only in the summary line.
   - **Override:** he can Resume a governor-paused job anyway, **at his own risk** — the button says so.
     An overridden job is not re-paused by the governor for the same condition.
4. **Resizable panes** — *"can these panes be resized?"* No: fixed halves, and four bars took the bottom
   half of the window. Offered: a draggable divider and bars that fold to one line.

## ⬜ FOR THE MORNING — his words, 2026-09-18 ~22:2x
***"the move status bars pushed the pane up so far 50% of the pane looks like icon view. it needs to be
adjustable in the morning"***
Cause: `PanePreview` is sized `containerRelativeFrame(.vertical) { height * 0.4 }` — 40% of the WINDOW,
not the pane. Four progress bars shrank the panes; the preview kept its size and the list fell to one row.
Fix wanted: an **adjustable** split between list and preview (drag), sized from the pane itself. Goes with
item 4 above (draggable pane divider, bars that fold to one line).

## Build 68 — Scan for Media, rebuilt from his report (2026-09-19 morning)

**His report:** *"i wanted to just select a drive and have it scan the whole drive for media but the
selected folder aparmtly didnt get scanned"* · *"when selecting the destination it said select music
folder when it should have said media"* · *"it has that popup and wouldnt allow me to do anything
else. it wasnt like last night where i was able to have four different status bars"* · and a beach
ball that made him force-quit from Xcode.

**His rules, same morning:** *"the photos should be copied using the enclosing photolibrarys database
to reinstate name and metadata"* · *"photos copied not moved"* · *"it should tell the user photos were
copied not moved because they were in {photolibrary name and filepath}"*.

- **Photos are media.** The scanner only knew audio and video, so photo folders came back empty.
- **Scan Whole Drive "<name>" for Media…** on the right-click menu. On the Mac's own drive it skips
  /Volumes (every other drive) and the system folders.
- **The walk is off the main thread** (`@concurrent`), with a Stop Scanning button and an items-looked-at count.
- **Photos libraries are never walked** — packaged or a plain-folder backup. Each is EXTRACTED through its
  own database (real names, dates), always COPIED. The summary names each library and its path.
- **Loose photos are always copied**, even when the action is Move. Audio and video follow the action.
- **Copy/Move go to the job system** (`FileOpMode.media`): the sheet closes, a bar takes over with Pause,
  clash questions (Skip / Keep Both), read-back check and the move log. The old copy loop ran on the
  main thread — that was the beach ball — and is gone.
- **"Music Library" → "Media Library"** in Settings, the folder picker and the right-click menu.
- Bug caught by the new test: two libraries extracting into one folder both claimed `IMG_0001.JPG`;
  names are now shared across the whole media job.
- Tests: new media suite ALL PASSED on the Mac drive, Raid and Cold Storage; last night's engine suite
  ALL PASSED (73). ⚠️ **Run the harness with `NGC_OPLOG_DIR` set** — without it the tests write their
  move logs into the REAL Operations folder (happened once this morning; 144 test logs, 20 Raid Trash
  items and 96 test lines in "Verified copies.tsv" were found and removed; his 9 real logs untouched).

## Build 69 — photos keep their folder (2026-09-19)

**His rule:** *"if the photos are loose the containing folder should be copied too ( that would mean the
[name] of the photolibrary in folder form and not the actual photolibrary"*. **His reason:** *"there are
usually so many photos vs other media types and they usually have obscure names"*.

- A loose photo lands in `Photos/<the folder it was in>/` — e.g. `…/Vacation 2019/c.jpg` → `Photos/Vacation 2019/c.jpg`.
- A library's photos land in a PLAIN folder named after it: `2025 09 11.photoslibrary` → `Photos/2025 09 11/`.
- **Photos never get an extension layer** (Claude's call, flagged to him): a library folder mixes JPG, HEIC
  and Live Photo videos, and an extension shelf would scatter it; loose photos follow the same rule so the
  two never disagree. Audio and video keep Audio/MP3, Video/MP4. With Flatten or By Extension there is no
  Photos/ shelf — the photo folders sit at the top.
- Rules live in `MediaPlan.build`, shared by the dialog and the test. Media suite ALL PASSED on Mac/Raid/Cold Storage.
- ⚠️ Known edge: rescanning a destination that already holds extracted libraries would re-shelve each
  Live Photo's .mov as a video. Not fixed; only matters if the result folder itself is scanned again.

## Build 70 — Delete is a job, and goes to the Trash where there is one (2026-09-19)

**Why:** a 2,655-folder delete on Cold Storage beach-balled the window — Delete ran on the main thread.
**His condition:** *"only if deleting to trash doesnt copy all the files to the trashcan and references
because if it takes an hour to copy from source to destination it is too long"* — **it does not copy.**
- Drive attached to this Mac (Mac drive, Raid) → **Trash**, which lives on that same drive: a rename.
  **Measured:** 2,000 files trashed in 0.01 s (Mac) / 0.04 s (Raid), SAME inode in the Trash.
- Network drive (Cold Storage) → **permanent**, as before (it has no Trash) — now off the main thread
  with a bar, Pause and Cancel; the summary says why. 2,000 files: 51.7 s, every item counted.
- ⛔ If the Trash refuses an item, NOTHING is deleted — it never falls back to erasing.
- Both delete paths (right-click, ⌘8) go through `FileOperationController.delete`.

## Build 72 — Add / Move to Media Library on the right-click menu (2026-09-19)
His ask: *"if im in a pane and i just want to move the selected file or folder to the designated media
folder why cant i?"* · *"i want add and move to media library options added please"*.
- **Add to Media Library** (copy) and **Move to Media Library**, for one item or a selection.
- Exactly what is selected, AS IS, into the designated folder — no media sorting (Claude's reading of
  "just move the selected file or folder"; the sorting question was asked and not answered).
- A normal job: bar, Pause, clash questions, read-back check, move log. Greyed out, with the reason in the
  label, when nothing is designated or its drive is not connected.
