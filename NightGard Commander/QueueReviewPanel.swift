//
//  QueueReviewPanel.swift
//  NightGard Commander
//
//  Created by Michael Fluharty with Claude on 2025 Nov 18 1105
//

import SwiftUI

struct QueueReviewPanel: View {
    @Binding var isPresented: Bool
    @State private var queue = ShazamQueue.shared
    let onSelectFile: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "list.bullet.clipboard")
                    .font(.title2)
                    .foregroundColor(.orange)
                Text("Shazam Queue")
                    .font(.title2)
                    .fontWeight(.semibold)

                Spacer()

                Text("\(queue.count()) files")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()

            Divider()

            // Queue list
            if queue.items.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundColor(.green)
                    Text("Queue is empty")
                        .font(.headline)
                    Text("All files have been processed!")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(queue.items) { item in
                            QueueItemRow(
                                item: item,
                                onSelect: {
                                    onSelectFile(item.filePath)
                                    isPresented = false
                                },
                                onRemove: {
                                    queue.remove(id: item.id)
                                }
                            )
                        }
                    }
                    .padding()
                }
            }

            Divider()

            // Footer actions
            HStack {
                if !queue.items.isEmpty {
                    Button(action: {
                        queue.removeAll()
                    }) {
                        Label("Clear Queue", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }

                Spacer()

                Button("Close") {
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(width: 600, height: 500)
    }
}

// Individual queue item row
struct QueueItemRow: View {
    let item: QueuedItem
    let onSelect: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // File icon
            Image(systemName: "music.note")
                .font(.title2)
                .foregroundColor(.orange)
                .frame(width: 32)

            // File info
            VStack(alignment: .leading, spacing: 4) {
                Text(item.fileName)
                    .font(.body)
                    .lineLimit(1)

                if let error = item.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .lineLimit(1)
                }

                if item.attemptCount > 1 {
                    Text("Attempts: \(item.attemptCount)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            // Actions
            HStack(spacing: 8) {
                Button(action: onSelect) {
                    Label("Edit", systemImage: "pencil")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                .help("Edit metadata manually")

                Button(action: onRemove) {
                    Label("Remove", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .help("Remove from queue")
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(8)
    }
}

#Preview {
    @Previewable @State var isPresented = true
    QueueReviewPanel(
        isPresented: $isPresented,
        onSelectFile: { _ in }
    )
}
