//
//  ShazamResultsDialog.swift
//  NightGard Commander
//
//  Created by Michael Fluharty with Claude on 2025 Nov 18 1100
//

import SwiftUI

struct ShazamResultsDialog: View {
    @Binding var isPresented: Bool
    let matchedCount: Int
    let queuedCount: Int
    let onViewQueue: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            // Success icon
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundColor(.green)

            // Title
            Text("Shazam Complete")
                .font(.title2)
                .fontWeight(.semibold)

            Divider()

            // Stats
            VStack(spacing: 12) {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("Successfully matched:")
                    Spacer()
                    Text("\(matchedCount) files")
                        .fontWeight(.semibold)
                }

                if queuedCount > 0 {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("Queued for review:")
                        Spacer()
                        Text("\(queuedCount) files")
                            .fontWeight(.semibold)
                    }
                }
            }
            .padding()
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(8)

            if matchedCount > 0 {
                Text("Files have been renamed and metadata saved.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()

            // Actions
            HStack(spacing: 12) {
                if queuedCount > 0 {
                    Button(action: {
                        onViewQueue()
                    }) {
                        Label("View Queue", systemImage: "list.bullet")
                    }
                    .buttonStyle(.bordered)
                }

                Spacer()

                Button("Done") {
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 450, height: queuedCount > 0 ? 350 : 300)
    }
}

#Preview {
    @Previewable @State var isPresented = true
    ShazamResultsDialog(
        isPresented: $isPresented,
        matchedCount: 1095,
        queuedCount: 5,
        onViewQueue: {}
    )
}
