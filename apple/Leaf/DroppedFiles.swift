import Foundation
import UniformTypeIdentifiers

/// Files dropped onto the Gallery, as temporary copies the Import can read after
/// the drop ended. The user's originals are never touched.
struct DroppedFiles {
    private let folder = URL.temporaryDirectory.appending(
        path: "Drop-\(UUID().uuidString)", directoryHint: .isDirectory)

    /// Whether `providers` hold at least one File of an Importable type.
    static func accepts(_ providers: [NSItemProvider]) -> Bool {
        providers.contains { provider in
            ImportableTypes.all.contains { provider.hasItemConformingToTypeIdentifier($0.identifier) }
        }
    }

    /// Copies of the Importable Files in `providers`, in drop order. Others are left out.
    @MainActor func receive(_ providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers {
            guard
                let type = ImportableTypes.all.first(where: {
                    provider.hasItemConformingToTypeIdentifier($0.identifier)
                }),
                let url = await copy(of: provider, type: type, index: urls.count)
            else { continue }
            urls.append(url)
        }
        return urls
    }

    func removeCopies() { try? FileManager.default.removeItem(at: folder) }

    /// The system deletes the File it hands over when the callback returns, so it is moved at once.
    @MainActor private func copy(of provider: NSItemProvider, type: UTType, index: Int) async -> URL? {
        let folder = folder
        let suggestedName = provider.suggestedName
        return await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { received, _ in
                guard let received else { return continuation.resume(returning: nil) }
                let directory = folder.appending(path: String(index), directoryHint: .isDirectory)
                // The system's copy may be named after the type; the dropped File's name is the Title's fallback.
                let suffix = "." + (type.preferredFilenameExtension ?? received.pathExtension)
                let name = suggestedName.map { $0.lowercased().hasSuffix(suffix) ? $0 : $0 + suffix }
                let copy = directory.appending(path: name ?? received.lastPathComponent)
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try FileManager.default.moveItem(at: received, to: copy)
                    continuation.resume(returning: copy)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
