import ARKit
import Foundation

/// One scan inside a project.
struct ScanInfo: Identifiable, Hashable {
    let url: URL
    var id: URL { url }
    var name: String { url.lastPathComponent }
    let frameCount: Int
    let pointCount: Int
}

/// A project = several scans of the same painting that share one AR coordinate system
/// (via a saved ARWorldMap), so they can be merged into a single dataset.
struct Project: Identifiable, Hashable {
    let url: URL
    var id: URL { url }
    var name: String { url.lastPathComponent }

    var scansDirectory: URL { url.appendingPathComponent("Scans", isDirectory: true) }
    var worldMapURL: URL { url.appendingPathComponent("worldmap.arworldmap") }
    var exportDirectory: URL { url.appendingPathComponent("Export", isDirectory: true) }
    var hasWorldMap: Bool { FileManager.default.fileExists(atPath: worldMapURL.path) }

    func scans() -> [ScanInfo] {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: scansDirectory, includingPropertiesForKeys: [.isDirectoryKey],
                                                options: [.skipsHiddenFiles])) ?? []
        return urls
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { url in
                ScanInfo(url: url,
                         frameCount: ScanWriter.loadFrames(in: url)?.count ?? 0,
                         pointCount: PointCloudIO.vertexCount(of: url.appendingPathComponent(ScanWriter.pointsFileName)) ?? 0)
            }
    }

    func newScanDirectory() throws -> URL {
        try FileManager.default.createDirectory(at: scansDirectory, withIntermediateDirectories: true)
        var index = scans().count + 1
        var url: URL
        repeat {
            url = scansDirectory.appendingPathComponent(String(format: "Scan_%03d", index), isDirectory: true)
            index += 1
        } while FileManager.default.fileExists(atPath: url.path)
        return url
    }

    func deleteScan(_ scan: ScanInfo) {
        try? FileManager.default.removeItem(at: scan.url)
    }

    func loadWorldMap() -> ARWorldMap? {
        guard let data = try? Data(contentsOf: worldMapURL) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data)
    }

    func saveWorldMap(_ map: ARWorldMap) throws {
        let data = try NSKeyedArchiver.archivedData(withRootObject: map, requiringSecureCoding: true)
        try data.write(to: worldMapURL, options: .atomic)
    }

    /// Points of all saved scans, decimated for display ("history points").
    func loadHistoryPoints(maxPoints: Int) -> [ColoredPoint] {
        let all = scans()
        guard !all.isEmpty else { return [] }
        let perScan = max(1, maxPoints / all.count)
        return all.flatMap {
            PointCloudIO.readPLY(url: $0.url.appendingPathComponent(ScanWriter.pointsFileName), maxPoints: perScan)
        }
    }
}

enum ProjectStore {
    static var root: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Projects", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func list() -> [Project] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey],
                                                                 options: [.skipsHiddenFiles])) ?? []
        return urls
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return a > b
            }
            .map { Project(url: $0) }
    }

    static func create(name: String) throws -> Project {
        let cleaned = name
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = cleaned.isEmpty ? "Painting" : cleaned
        var url = root.appendingPathComponent(base, isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = root.appendingPathComponent("\(base) \(n)", isDirectory: true)
            n += 1
        }
        let project = Project(url: url)
        try FileManager.default.createDirectory(at: project.scansDirectory, withIntermediateDirectories: true)
        return project
    }

    static func delete(_ project: Project) {
        try? FileManager.default.removeItem(at: project.url)
    }

    static var lastOpenedName: String? {
        get { UserDefaults.standard.string(forKey: "lastOpenedProject") }
        set { UserDefaults.standard.set(newValue, forKey: "lastOpenedProject") }
    }

    static func openOrCreateDefault() -> Project? {
        if let name = lastOpenedName {
            let url = root.appendingPathComponent(name, isDirectory: true)
            if FileManager.default.fileExists(atPath: url.path) { return Project(url: url) }
        }
        return list().first ?? (try? create(name: "Painting 1"))
    }

    /// Zips a folder with the system's built-in "for uploading" coordinator (no third-party library).
    static func zip(_ folder: URL, name: String) throws -> URL {
        var result: URL?
        var innerError: Error?
        var coordinatorError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &coordinatorError) { zipURL in
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent(name + ".zip")
            try? FileManager.default.removeItem(at: dest)
            do {
                try FileManager.default.copyItem(at: zipURL, to: dest)
                result = dest
            } catch {
                innerError = error
            }
        }
        if let error = coordinatorError ?? innerError { throw error }
        guard let url = result else { throw CocoaError(.fileWriteUnknown) }
        return url
    }
}
