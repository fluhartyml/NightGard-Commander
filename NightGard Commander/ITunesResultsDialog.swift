//
//  ITunesResultsDialog.swift
//  NightGard Commander
//
//  Created by Michael Fluharty with Claude on 2025 Nov 19 1155
//

import SwiftUI

struct ITunesResultsDialog: View {
    @Binding var isPresented: Bool
    let matchedCount: Int
    let unmatchedCount: Int

    var body: some View {
        VStack(spacing: 20) {
            // Success icon
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundColor(.green)

            // Title
            Text("iTunes Lookup Complete")
                .font(.title2)
                .fontWeight(.semibold)

            Divider()

            // Stats
            VStack(spacing: 12) {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("Successfully updated:")
                    Spacer()
                    Text("\(matchedCount) files")
                        .fontWeight(.semibold)
                }

                if unmatchedCount > 0 {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("Not found in iTunes:")
                        Spacer()
                        Text("\(unmatchedCount) files")
                            .fontWeight(.semibold)
                    }
                }
            }
            .padding()
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(8)

            if matchedCount > 0 {
                VStack(spacing: 4) {
                    Text("Metadata updated with:")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    HStack(spacing: 12) {
                        Label("Album", systemImage: "square.stack")
                        Label("Track #", systemImage: "number")
                        Label("Year", systemImage: "calendar")
                        Label("Artwork", systemImage: "photo")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
            }

            Divider()

            // Actions
            HStack(spacing: 12) {
                Spacer()

                Button("Done") {
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 450, height: unmatchedCount > 0 ? 380 : 320)
    }
}

#Preview {
    @Previewable @State var isPresented = true
    ITunesResultsDialog(
        isPresented: $isPresented,
        matchedCount: 1095,
        unmatchedCount: 5
    )
}
