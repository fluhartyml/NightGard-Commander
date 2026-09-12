//
//  BuildStamp.swift
//  NightGard Commander
//
//  ⚠️ THE VALUES BELOW ARE REWRITTEN BY `Scripts/stamp-build.sh`. Do not hand-edit them.
//
//  This repository had no build-number machinery at all until 2026-09-11, so every build
//  it ever produced called itself "1.0 (1)" — the same condition that cost a full day on
//  Shell Citadel, when an iPad kept working, three iPhones did not, and none of the four
//  could say which build it was running.
//
//  Michael, 2026-09-04: "you need to make sure it happens and you do not get complaicent
//  and not do it in the future."
//
//  So it is not a habit. Scripts/post-commit rewrites the build number after every
//  commit, and Scripts/install-hooks.sh puts that hook in place — git never copies hooks
//  on clone, so the hook has to be installed from something the repository carries.

import Foundation

enum BuildStamp {
    /// Short SHA of HEAD when this build was stamped. "+" suffix = uncommitted changes.
    static let commit = "c20d037"

    /// Branch HEAD was on when this build was stamped.
    static let branch = "lost_its_mind"

    /// Local time the stamp was generated — effectively the build time.
    static let built = "2026-09-11 18:46"

    /// True when this binary was never stamped. Not a missing answer — it IS the answer:
    /// this build predates stamping, so it is older than any stamped one.
    static var isStamped: Bool { commit != "unstamped" }

    /// The build number — `CURRENT_PROJECT_VERSION`, which is the git commit count.
    ///
    /// ⚠️ READ FROM THE BUNDLE, NOT STAMPED INTO THIS FILE. It is already written into
    /// the project by `Scripts/stamp-build.sh`, and a second copy here could disagree
    /// with the first. One source, so there is nothing to keep in step.
    static var number: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }

    /// Marketing version, for the line that gets read out loud.
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    /// One line, readable out loud off the screen by someone who cannot see Xcode.
    static var summary: String {
        isStamped
            ? "Version \(version)  ·  Build \(number)  ·  \(commit) (\(branch))  ·  built \(built)"
            : "Version \(version)  ·  Build \(number)  ·  unstamped build"
    }
}
