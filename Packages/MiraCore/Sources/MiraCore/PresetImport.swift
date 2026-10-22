import Foundation

/// What to do when an imported preset has the same "<film> - <nickname>" as one already saved.
public enum PresetImportChoice: Sendable, Equatable {
    case replace, keepBoth, skip
}

public struct PresetImportFailure: Sendable, Equatable {
    public var fileName: String
    public var reason: String
}

/// What an import did, for the notice.
public struct PresetImportOutcome: Sendable, Equatable {
    public var added: [Preset] = []
    public var replaced: [Preset] = []
    public var skipped: [String] = []
    public var failures: [PresetImportFailure] = []

    public init() {}

    public var importedCount: Int { added.count + replaced.count }

    /// "Imported 3 presets. Replaced 1. Skipped 1. Could not import: a.mirapreset (not a Mira preset file)."
    public var summary: String {
        var parts: [String] = []
        if importedCount > 0 {
            parts.append("Imported \(importedCount) \(importedCount == 1 ? "preset" : "presets")")
            if !replaced.isEmpty { parts[parts.count - 1] += " (\(replaced.count) replaced)" }
        } else if failures.isEmpty && skipped.isEmpty {
            parts.append("No presets imported")
        }
        if !skipped.isEmpty { parts.append("Skipped \(skipped.count)") }
        if !failures.isEmpty {
            let list = failures.map { "\($0.fileName) (\($0.reason))" }.joined(separator: ", ")
            parts.append("Could not import: \(list)")
        }
        return parts.joined(separator: ". ") + "."
    }
}

extension PresetStore {
    /// Reads each file and adds its preset. A preset whose display name is already saved goes to
    /// `resolve` (incoming, the saved one, how many conflicts may still follow) for a choice. Unreadable
    /// files are listed in the outcome by file name; the rest still import.
    public func importPresets(
        from urls: [URL],
        resolve: @MainActor (_ incoming: Preset, _ existing: Preset, _ remaining: Int) async -> PresetImportChoice
    ) async -> PresetImportOutcome {
        var outcome = PresetImportOutcome()
        var parsed: [(url: URL, preset: Preset)] = []
        for url in urls {
            do {
                parsed.append((url, try PresetFile.read(url)))
            } catch let error as PresetFileError {
                outcome.failures.append(.init(fileName: url.lastPathComponent, reason: error.description))
            } catch {
                outcome.failures.append(.init(fileName: url.lastPathComponent, reason: PresetFileError.unreadable.description))
            }
        }
        for (index, item) in parsed.enumerated() {
            var incoming = item.preset
            let current = all
            if let existing = current.first(where: { PresetFile.key($0.displayName) == PresetFile.key(incoming.displayName) }) {
                let remaining = parsed[(index + 1)...].filter { later in
                    current.contains { PresetFile.key($0.displayName) == PresetFile.key(later.preset.displayName) }
                }.count
                switch await resolve(incoming, existing, remaining) {
                case .skip:
                    outcome.skipped.append(incoming.displayName)
                    continue
                case .replace:
                    do {
                        outcome.replaced.append(try replace(id: existing.id, with: incoming))
                    } catch {
                        outcome.failures.append(.init(fileName: item.url.lastPathComponent, reason: "the preset could not be saved"))
                    }
                    continue
                case .keepBoth:
                    incoming.nickname = PresetFile.uniqueNickname(incoming.nickname, filmName: incoming.filmName, among: current)
                }
            }
            do {
                outcome.added.append(try add(incoming))
            } catch {
                outcome.failures.append(.init(fileName: item.url.lastPathComponent, reason: "the preset could not be saved"))
            }
        }
        return outcome
    }
}
