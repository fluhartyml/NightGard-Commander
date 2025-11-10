//
//  NightGard_CommanderApp.swift
//  NightGard Commander
//
//  Created by Michael Fluharty on 11/10/25.
//

import SwiftUI
import CoreData

@main
struct NightGard_CommanderApp: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
