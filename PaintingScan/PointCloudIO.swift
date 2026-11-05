import Foundation

/// One coloured 3D point in AR world coordinates (metres).
struct ColoredPoint {
    var x: Float
    var y: Float
    var z: Float
    var r: UInt8
    var g: UInt8
    var b: UInt8
}

extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { self.append(contentsOf: $0) }
    }
    mutating func appendLE(_ value: Float) { appendLE(value.bitPattern) }
    mutating func appendLE(_ value: Double) { appendLE(value.bitPattern) }
}

/// Binary little-endian PLY with float x/y/z and uchar red/green/blue (15 bytes per point).
enum PointCloudIO {
    static let recordSize = 15

    static func header(count: Int) -> Data {
        let text = """
        ply
        format binary_little_endian 1.0
        element vertex \(count)
        property float x
        property float y
        property float z
        property uchar red
        property uchar green
        property uchar blue
        end_header

        """
        return Data(text.utf8)
    }

    static func append(_ p: ColoredPoint, to data: inout Data) {
        data.appendLE(p.x)
        data.appendLE(p.y)
        data.appendLE(p.z)
        data.append(p.r)
        data.append(p.g)
        data.append(p.b)
    }

    static func writePLY(_ points: [ColoredPoint], to url: URL) throws {
        var data = header(count: points.count)
        data.reserveCapacity(data.count + points.count * recordSize)
        for p in points { append(p, to: &data) }
        try data.write(to: url, options: .atomic)
    }

    /// Number of complete points in a PLY written by this app (reads only the header).
    static func vertexCount(of url: URL) -> Int? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 1024),
              let end = head.range(of: Data("end_header\n".utf8)),
              let text = String(data: head[head.startIndex..<end.upperBound], encoding: .ascii),
              let declared = parseCount(text) else { return nil }
        let headerLength = end.upperBound - head.startIndex
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        return min(declared, max(0, (size - headerLength) / recordSize))
    }

    /// Reads points, keeping at most `maxPoints` (evenly decimated).
    static func readPLY(url: URL, maxPoints: Int = .max) -> [ColoredPoint] {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let end = data.range(of: Data("end_header\n".utf8)),
              let text = String(data: data[data.startIndex..<end.upperBound], encoding: .ascii),
              let declared = parseCount(text) else { return [] }

        let start = end.upperBound - data.startIndex
        let available = (data.count - start) / recordSize
        let n = min(declared, available)
        guard n > 0 else { return [] }
        let step = max(1, n / max(1, maxPoints))

        var out: [ColoredPoint] = []
        out.reserveCapacity(n / step + 1)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var i = 0
            while i < n {
                let o = start + i * recordSize
                let x = Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: o, as: UInt32.self)))
                let y = Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: o + 4, as: UInt32.self)))
                let z = Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: o + 8, as: UInt32.self)))
                out.append(ColoredPoint(x: x, y: y, z: z, r: raw[o + 12], g: raw[o + 13], b: raw[o + 14]))
                i += step
            }
        }
        return out
    }

    private static func parseCount(_ header: String) -> Int? {
        for line in header.split(separator: "\n") where line.hasPrefix("element vertex ") {
            return Int(line.dropFirst("element vertex ".count).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }
}
