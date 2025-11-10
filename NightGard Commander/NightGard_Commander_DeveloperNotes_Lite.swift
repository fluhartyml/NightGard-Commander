//
//  NightGard_Commander_DeveloperNotes_Lite.swift
//  NightGard Commander
//
//  Created by Michael Fluharty on 11/10/25.
//

/*

 # NightGard Commander - Developer Notes (Lite)

 **Module Name:** NightGard Commander
 **Type:** macOS/iOS File Manager (Future Swift Package)
 **Created:** 2025-NOV-10
 **Developer:** Michael Fluharty (michael@fluharty.com)
 **Attribution:** Inspired by Midnight Commander and its predecessor Norton Commander

 ---

 ## Project Description

 NightGard Commander is a dual-pane file manager for macOS and iPad, inspired by the classic Norton Commander and Midnight Commander. Built with SwiftUI and designed as a modular component library that other developers can integrate into their applications.

 **Primary Use Case:** Fast navigation to workspace folders via bookmarks/favorites

 **Core Features:**
 - Dual-pane file browser (left/right panels)
 - Bookmark/favorites system (critical feature)
 - Path history and quick navigation
 - File operations (copy, move, delete, rename)
 - Cross-platform: Mac (local filesystem) + iPad (SSH to Mac)
 - Core Data + CloudKit for bookmark sync

 **Supported Platforms:**
 - macOS 26+
 - iOS 26+ (iPad optimized, SSH mode)

 ---

 ## Design Philosophy

 1. **Modular Architecture** - Built as reusable UI components from day one
 2. **UI-Complete Modules** - Modules include full UI, not just backend logic
 3. **End Developer Focus** - Built for developers who will integrate our components
 4. **Navigation First** - File operations secondary to workspace navigation
 5. **Real Functionality** - Avoid placeholders, build working features immediately

 ### The Module Vision

 NightGard Commander isn't just a standalone app - it's designed to be decomposed into reusable components:
 - `DualPaneFileManager` - Complete dual-pane UI component
 - `FileBrowserPanel` - Single-pane file browser
 - `FileOperationsService` - Copy/move/delete backend
 - `BookmarkManager` - Favorites/quick access system

 Other developers can import these components and drop them into their own apps.

 ---

 ## Architecture Notes

 **Persistence:**
 - Core Data + CloudKit for bookmark/settings sync
 - UserDefaults for lightweight preferences
 - Bookmarks sync between Mac and iPad via iCloud

 **Platform Strategy:**
 - **Mac:** Direct local filesystem access via FileManager
 - **iPad:** SSH connection to Mac, executes commands remotely
 - Both platforms use same UI, different execution layer

 **SSH Mode (iPad):**
 - User configures SSH host/credentials once
 - Commands execute on Mac via SSH
 - iPad sees Mac's filesystem, not local copy
 - No file duplication or sync conflicts

 ---

 ## Current Status

 **Phase:** Initial development
 **Git:** Connected to GitHub
 **Template:** Xcode Core Data + CloudKit template (boilerplate to be replaced)
 **Next:** Replace demo ContentView with dual-pane file browser UI

 ---

 ## Attribution

 This project is officially inspired by:
 - **Norton Commander** (Peter Norton, 1986-1998)
 - **Midnight Commander** (Miguel de Icaza, 1994-present, GNU GPL v3)

 NightGard Commander is an original work, not a fork or derivative. We honor the legacy of these pioneering file managers that defined the "Commander" interface pattern.

 Reference repository: https://github.com/fluhartyml/mc (forked for study)

 ---

 ## Quick Reference

 **Location:** `/Users/michaelfluharty/Developer/NightGard/NightGard Commander/`
 **Bundle ID:** `com.NightGard.NightGard-Commander`
 **Distribution:** GitHub (no App Sandbox, requires unrestricted filesystem access)

 **Key Files:**
 - `NightGard_CommanderApp.swift` - App entry point
 - `ContentView.swift` - Main UI (to be replaced with dual-pane layout)
 - `Persistence.swift` - Core Data + CloudKit setup
 - `NightGard_Commander.xcdatamodeld` - Core Data model (bookmarks, settings)

 ---

 ## Developer Memory

 This is a "lite" version of developer notes. For comprehensive project history, workflows, and policies, see:
 `/Users/michaelfluharty/Developer/NightGard/CLI Claude/Memory/NG_DeveloperNotes.md`

 This file contains only essential project-specific information for NightGard Commander module development.

 ---

 *NightGard Commander - File management for the modern developer*
 *www.fluharty.me*

 */
