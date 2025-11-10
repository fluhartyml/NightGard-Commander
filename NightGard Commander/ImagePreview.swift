//
//  ImagePreview.swift
//  NightGard Commander
//
//  Created by Michael Fluharty on 11/10/25.
//

import SwiftUI

struct ImagePreview: View {
    let filePath: String
    let fileName: String
    let onClose: () -> Void

    @State private var image: NSImage?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var scale: CGFloat = 1.0

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "photo")
                    .font(.title3)
                Text(fileName)
                    .font(.headline)
                    .lineLimit(1)

                Spacer()

                if let img = image {
                    Text("\(Int(img.size.width)) × \(Int(img.size.height))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Button("Close") {
                    onClose()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding()
            .background(Color.secondary.opacity(0.1))

            Divider()

            // Image display
            if isLoading {
                ProgressView("Loading image...")
                    .padding()
            } else if let error = errorMessage {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 50))
                        .foregroundColor(.orange)
                    Text(error)
                        .foregroundColor(.red)
                }
                .padding()
            } else if let img = image {
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(scale)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .background(Color.black.opacity(0.05))
            }

            Divider()

            // Footer with zoom controls
            HStack {
                Text(filePath)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                if image != nil {
                    HStack(spacing: 8) {
                        Button(action: { scale = max(0.1, scale - 0.25) }) {
                            Image(systemName: "minus.magnifyingglass")
                        }
                        .buttonStyle(.borderless)

                        Text("\(Int(scale * 100))%")
                            .font(.caption)
                            .frame(width: 50)

                        Button(action: { scale = min(5.0, scale + 0.25) }) {
                            Image(systemName: "plus.magnifyingglass")
                        }
                        .buttonStyle(.borderless)

                        Button(action: { scale = 1.0 }) {
                            Text("100%")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .padding(8)
            .background(Color.secondary.opacity(0.05))
        }
        .frame(minWidth: 600, minHeight: 400)
        .onAppear {
            loadImage()
        }
    }

    private func loadImage() {
        isLoading = true
        errorMessage = nil

        DispatchQueue.global(qos: .userInitiated).async {
            if let nsImage = NSImage(contentsOfFile: filePath) {
                DispatchQueue.main.async {
                    self.image = nsImage
                    self.isLoading = false
                }
            } else {
                DispatchQueue.main.async {
                    self.errorMessage = "Failed to load image"
                    self.isLoading = false
                }
            }
        }
    }
}
