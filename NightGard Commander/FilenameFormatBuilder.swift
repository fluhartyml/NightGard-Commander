//
//  FilenameFormatBuilder.swift
//  NightGard Commander
//
//  Created by Michael Fluharty with Claude on 2025 Nov 18 0820
//

import SwiftUI
import UniformTypeIdentifiers

// Available metadata fields for filename formatting
enum MetadataField: String, CaseIterable, Identifiable {
    case title = "Title"
    case artist = "Artist"
    case albumName = "Album"
    case genres = "Genre"
    case releaseDate = "Release Date"
    case year = "Year"
    case trackNumber = "Track #"
    case explicitContent = "Explicit Flag"
    case appleMusicID = "Apple Music ID"
    case appleMusicURL = "Apple Music URL"
    case webURL = "Web URL"
    case separator = "-"

    var id: String { rawValue }

    var displayName: String { rawValue }

    // For preview generation
    func sampleValue() -> String {
        switch self {
        case .title: return "Title"
        case .artist: return "Artist"
        case .albumName: return "Album"
        case .genres: return "Genre"
        case .releaseDate: return "YYYY-MM-DD"
        case .year: return "YYYY"
        case .trackNumber: return "##"
        case .explicitContent: return "Flag"
        case .appleMusicID: return "ID"
        case .appleMusicURL: return "URL"
        case .webURL: return "URL"
        case .separator: return " - "
        }
    }
}

// Individual format block
struct FormatBlock: Identifiable, Equatable {
    let id = UUID()
    var field: MetadataField
}

struct FilenameFormatBuilder: View {
    @Binding var isPresented: Bool
    @Binding var formatBlocks: [FormatBlock]

    @State private var selectedBlockID: UUID?
    @State private var blocks: [FormatBlock] = []
    @State private var draggedBlock: FormatBlock?

    var body: some View {
        VStack(spacing: 20) {
            // Title
            Text("Filename Format Builder")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Build your custom filename format using metadata fields")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Divider()

            // Blocks area
            VStack(alignment: .leading, spacing: 12) {
                Text("Format Blocks:")
                    .font(.caption)
                    .foregroundColor(.secondary)

                ScrollView(.horizontal, showsIndicators: true) {
                    HStack(spacing: 8) {
                        if blocks.isEmpty {
                            Text("Click + to add your first block")
                                .foregroundColor(.secondary)
                                .italic()
                                .padding()
                        } else {
                            ForEach(blocks) { block in
                                BlockView(
                                    block: block,
                                    isSelected: selectedBlockID == block.id,
                                    onSelect: {
                                        selectedBlockID = block.id
                                    },
                                    onFieldChange: { newField in
                                        if let index = blocks.firstIndex(where: { $0.id == block.id }) {
                                            blocks[index].field = newField
                                        }
                                    }
                                )
                                .onDrag {
                                    draggedBlock = block
                                    return NSItemProvider(object: block.id.uuidString as NSString)
                                }
                                .onDrop(of: [.text], delegate: BlockDropDelegate(
                                    block: block,
                                    blocks: $blocks,
                                    draggedBlock: $draggedBlock
                                ))
                            }
                        }
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 4)
                }
                .frame(height: 80)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(8)
            }

            // Controls: + and - buttons
            HStack(spacing: 16) {
                Button(action: addBlock) {
                    Label("Add Block", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(blocks.count >= 10) // Reasonable limit

                Button(action: removeSelectedBlock) {
                    Label("Remove Block", systemImage: "minus.circle.fill")
                }
                .buttonStyle(.bordered)
                .disabled(selectedBlockID == nil)

                Spacer()

                if selectedBlockID == nil {
                    Text("Click a block to select it")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Divider()

            // Preview
            VStack(alignment: .leading, spacing: 8) {
                Text("Preview:")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text(generatePreview())
                    .font(.system(.body, design: .monospaced))
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(8)
            }

            Divider()

            // Action buttons
            HStack {
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Finished") {
                    formatBlocks = blocks
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(blocks.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 700, height: 450)
        .onAppear {
            // Initialize with existing blocks or default
            if formatBlocks.isEmpty {
                blocks = [
                    FormatBlock(field: .artist),
                    FormatBlock(field: .separator),
                    FormatBlock(field: .title),
                    FormatBlock(field: .separator),
                    FormatBlock(field: .albumName)
                ]
            } else {
                blocks = formatBlocks
            }
        }
    }

    private func addBlock() {
        let newBlock = FormatBlock(field: .separator)

        if let selectedID = selectedBlockID,
           let index = blocks.firstIndex(where: { $0.id == selectedID }) {
            // Insert after selected block
            blocks.insert(newBlock, at: index + 1)
        } else {
            // Append to end
            blocks.append(newBlock)
        }

        selectedBlockID = newBlock.id
    }

    private func removeSelectedBlock() {
        guard let selectedID = selectedBlockID else { return }
        blocks.removeAll { $0.id == selectedID }
        selectedBlockID = nil
    }

    private func generatePreview() -> String {
        if blocks.isEmpty {
            return "No format configured"
        }

        let parts = blocks.map { $0.field.sampleValue() }
        return parts.joined() + ".mp3"
    }
}

// Individual block view with picker
struct BlockView: View {
    let block: FormatBlock
    let isSelected: Bool
    let onSelect: () -> Void
    let onFieldChange: (MetadataField) -> Void

    @State private var selectedField: MetadataField

    init(block: FormatBlock, isSelected: Bool, onSelect: @escaping () -> Void, onFieldChange: @escaping (MetadataField) -> Void) {
        self.block = block
        self.isSelected = isSelected
        self.onSelect = onSelect
        self.onFieldChange = onFieldChange
        _selectedField = State(initialValue: block.field)
    }

    var body: some View {
        VStack(spacing: 4) {
            Picker("", selection: $selectedField) {
                ForEach(MetadataField.allCases) { field in
                    Text(field.displayName).tag(field)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 100)
            .onChange(of: selectedField) { oldValue, newValue in
                onFieldChange(newValue)
            }

            // Selection indicator
            Rectangle()
                .fill(isSelected ? Color.blue : Color.clear)
                .frame(height: 3)
        }
        .padding(8)
        .frame(width: 120)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.blue.opacity(0.2) : Color.secondary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 2)
        )
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .onTapGesture {
            onSelect()
        }
    }
}

// Drop delegate for reordering blocks
struct BlockDropDelegate: DropDelegate {
    let block: FormatBlock
    @Binding var blocks: [FormatBlock]
    @Binding var draggedBlock: FormatBlock?

    func performDrop(info: DropInfo) -> Bool {
        draggedBlock = nil
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let draggedBlock = draggedBlock else { return }
        guard draggedBlock.id != block.id else { return }

        guard let fromIndex = blocks.firstIndex(where: { $0.id == draggedBlock.id }),
              let toIndex = blocks.firstIndex(where: { $0.id == block.id }) else {
            return
        }

        withAnimation(.default) {
            blocks.move(fromOffsets: IndexSet(integer: fromIndex), toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex)
        }
    }
}

#Preview {
    @Previewable @State var isPresented = true
    @Previewable @State var blocks: [FormatBlock] = []

    FilenameFormatBuilder(isPresented: $isPresented, formatBlocks: $blocks)
}
