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
    let genreReviewCount: Int
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

                if genreReviewCount > 0 {
                    HStack {
                        Image(systemName: "pencil.circle.fill")
                            .foregroundColor(.purple)
                        Text("Need genre selection:")
                        Spacer()
                        Text("\(genreReviewCount) files")
                            .fontWeight(.semibold)
                    }
                }

                if queuedCount > 0 {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("Failed to match:")
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
                if genreReviewCount > 0 || queuedCount > 0 {
                    Text("Matched files have been renamed. Review queue to complete remaining files.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("All files have been successfully processed and renamed.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Divider()

            // Actions
            HStack(spacing: 12) {
                if genreReviewCount > 0 || queuedCount > 0 {
                    Button(action: {
                        onViewQueue()
                    }) {
                        Label("Review Queue", systemImage: "list.bullet.clipboard")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(genreReviewCount > 0 ? .purple : .orange)
                }

                Spacer()

                if genreReviewCount > 0 || queuedCount > 0 {
                    Button("Done") {
                        isPresented = false
                    }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("Done") {
                        isPresented = false
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 450, height: (genreReviewCount > 0 || queuedCount > 0) ? 380 : 300)
    }
}

#Preview {
    @Previewable @State var isPresented = true
    ShazamResultsDialog(
        isPresented: $isPresented,
        matchedCount: 1095,
        genreReviewCount: 12,
        queuedCount: 5,
        onViewQueue: {}
    )
}
