# NightGard Commander

A two-pane file manager for the Mac in the tradition of Midnight Commander, with a media
player built in.

## Copy and Move

- A folder that is already in the target asks **Merge · Replace · Skip · Cancel**; a folder
  Replace asks a second time and says how many files it removes.
- A file that is already there asks **Replace · Replace if newer · Replace if size differs ·
  Skip · Keep Both**, with both files shown side by side. Identical files are asked about too.
- Every question is asked before anything moves, so Cancel during the questions changes
  nothing.
- A move across drives copies each file, reads the copy back to prove it matches, and only
  then deletes the original. Anything skipped stays where it was.
- Replaced items go to the Trash. A network drive has no Trash, and the question says so
  before anything is deleted.
- Photos, Music and TV libraries are handled as one item and never merged file by file. A
  library an app is using is copied, never moved.
- Pause, Cancel, a summary at the end, and **Edit › Undo Last Move…** for a whole move.

## Acknowledgments

- **GNU Midnight Commander** — <https://midnight-commander.org>, GPL v3 or later. Copy and
  Move follow its approach (a same-drive move is a rename; a cross-drive move deletes the
  source only after the copy succeeds; Replace if newer / if size differs; never overwrite a
  real file with an empty one). The ideas were rewritten in Swift; no Midnight Commander code
  is included.

Copyright covers Michael Fluharty's original work only. It does not claim or intend
ownership of the work of the original developers named here.
