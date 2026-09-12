//
//  CLIRunner.swift
//  NightGard Commander
//
//  Created by Michael Fluharty with Claude on 2026 Sep 10
//
//  Headless command-line mode. Additive only: if no recognised verb is present
//  on the command line, this returns immediately and the app launches normally.
//
//  Usage:
//    NightGard\ Commander --scan <folder>
//    NightGard\ Commander --shazam <folder>
//    NightGard\ Commander --itunes <folder>
//    NightGard\ Commander --reformat
//    NightGard\ Commander --detect <file>
//    NightGard\ Commander --set-music-library <folder>
//    NightGard\ Commander --music-library
//
//  ⚠️ THE CLI AND THE INTERFACE MUST STAY IN STEP. Michael, 2026-09-11: the notes on
//  what we do in the app exist so the same thing can be done from the command line.
//  Anything the interface can designate or configure needs a verb here, reading and
//  writing the SAME UserDefaults the interface uses — never a second store.
//

import Foundation

enum CLIRunner {

    private static func out(_ s: String) {
        FileHandle.standardOutput.write((s + "\n").data(using: .utf8)!)
    }

    private static func usage() {
        out("""
        NightGard Commander — command line mode

          --scan <folder>     list every media file found under <folder>
          --shazam <folder>   batch Shazam every audio file under <folder>
          --itunes <folder>   batch identify via the iTunes API instead of Shazam
          --reformat          rename from the already-scanned database, no network
          --detect <file>     identify one file and print the result

          --set-music-library <folder>
                              designate the target music library parent directory.
                              Same setting the right-click item writes; persists.
          --music-library     print the designated target
                              exit 0 designated and reachable, 1 none, 2 unreachable
          --clear-music-library
                              remove the designation
          --check-move <path> say whether a file may be moved, or is copy-only
                              because another app owns it. exit 0 movable, 1 copy-only
          --version           print version, build number, commit and build time

          --help              this text

        Any other invocation launches the normal interface.
        """)
    }

    /// Runs a headless job if one was requested, then exits.
    /// Returns without side effects when the app was launched normally.
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard args.count > 1 else { return }

        let verb = args[1]
        let known = ["--scan", "--shazam", "--itunes", "--reformat", "--detect",
                     "--set-music-library", "--music-library", "--clear-music-library",
                     "--check-move", "--version", "--help"]
        // ⛔ AN UNRECOGNISED --VERB IS AN ERROR, NOT A REASON TO OPEN THE WINDOW.
        // 2026-09-11: --check-move was implemented but never added to `known`, so it
        // fell through here and launched the interface. From the terminal that is
        // indistinguishable from a hang, and it sent the diagnosis somewhere else
        // entirely. A typo should say so.
        //
        // Anything not starting with "--" still falls through untouched, so a normal
        // launch and Xcode's own arguments are unaffected.
        if verb.hasPrefix("--") && !known.contains(verb) {
            out("error: unknown option \(verb)")
            usage()
            exit(2)
        }
        guard known.contains(verb) else { return }

        if verb == "--help" { usage(); exit(0) }

        // Answered before the Task below, because none of these touch the MainActor
        // work and there is no reason to spin up a run loop to print one line.
        if verb == "--version" {
            out(BuildStamp.summary)
            exit(0)
        }

        if verb == "--music-library" {
            let p = ShazamSettings.shared.musicLibraryPath
            if p.isEmpty {
                out("no target music library designated")
                exit(1)
            }
            out(p)
            // A designated folder can be on an unmounted drive. Say so rather than
            // letting the caller act on a path that is not there.
            var isDir: ObjCBool = false
            let ok = FileManager.default.fileExists(atPath: p, isDirectory: &isDir) && isDir.boolValue
            exit(ok ? 0 : 2)
        }

        // Exists so the copy-only guardrail can be tested in BOTH directions.
        // A guard that can only ever say yes is not a guard.
        if verb == "--check-move" {
            guard args.count > 2 else {
                out("error: --check-move needs a path")
                exit(2)
            }
            let path = (args[2] as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: path)
            if MoveGuard.mustCopyNotMove(url) {
                out("COPY ONLY — owned by another app: \(path)")
                exit(1)
            }
            out("movable: \(path)")
            exit(0)
        }

        if verb == "--clear-music-library" {
            ShazamSettings.shared.musicLibraryPath = ""
            UserDefaults.standard.synchronize()
            out("target music library cleared")
            exit(0)
        }

        if verb == "--set-music-library" {
            guard args.count > 2 else {
                out("error: --set-music-library needs a folder")
                exit(2)
            }
            let path = (args[2] as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
                out("error: not a folder: \(path)")
                exit(2)
            }
            // Resolve to an absolute standardised path so the interface and the CLI
            // compare equal — the right-click check is a string comparison.
            let resolved = URL(fileURLWithPath: path).standardizedFileURL.path
            ShazamSettings.shared.musicLibraryPath = resolved
            UserDefaults.standard.synchronize()
            out("target music library: \(resolved)")
            exit(0)
        }

        func argPath() -> String {
            guard args.count > 2 else {
                out("error: \(verb) needs a path")
                exit(2)
            }
            return (args[2] as NSString).expandingTildeInPath
        }

        // NOTE: the work below is MainActor-isolated, so the main thread must be
        // left free to run it. Blocking here on a semaphore deadlocks. Instead the
        // job is scheduled and the main run loop is started; the task exits the
        // process itself when it finishes.
        Task { @MainActor in
            switch verb {

            case "--scan":
                let path = argPath()
                let urls = await MediaScanner().scanFolder(at: URL(fileURLWithPath: path))
                for u in urls { out(u.path) }
                out("— \(urls.count) media files")

            case "--shazam":
                let path = argPath()
                out("shazam: \(path)")
                await ShazamService.shared.processFolder(path: path)
                out("— shazam pass complete")

            case "--itunes":
                let path = argPath()
                let r = await ShazamService.shared.processWithiTunesAPI(path: path)
                out("processed=\(r.processed) renamed=\(r.renamed) skipped=\(r.skipped) errors=\(r.errors)")

            case "--reformat":
                let r = await ShazamService.shared.reformatAllFromDatabase()
                out("renamed=\(r.renamed) skipped=\(r.skipped) errors=\(r.errors)")

            case "--detect":
                let path = argPath()
                let r = await ShazamService.shared.detectFile(path: path)
                if r.matched {
                    out("matched: \(r.artist ?? "?") — \(r.title ?? "?")  album=\(r.album ?? "?")  genre=\(r.genre ?? "?")  year=\(r.year ?? "?")")
                } else {
                    out("no match: \(r.error ?? "unidentified")")
                }

            default:
                usage()
            }
            exit(0)
        }

        RunLoop.main.run()
    }
}
