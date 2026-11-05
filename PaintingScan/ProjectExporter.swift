import Foundation
import simd

/// Merges all scans of a project into one dataset that needs no COLMAP / SfM step:
///
///   Export/
///     images/s01_frame_00000.jpg ...
///     depth/, confidence/                       LiDAR maps (same names, .png)
///     sparse/0/cameras.bin|txt                  PINHOLE camera per image (exact ARKit intrinsics)
///     sparse/0/images.bin|txt                   ARKit poses converted to COLMAP world-to-camera
///     sparse/0/points3D.bin|txt                 LiDAR points (initialisation for Gaussian Splatting)
///     transforms.json                           Nerfstudio format (same poses, OpenGL convention)
///     sparse_pc.ply                             merged coloured point cloud
///
/// Load the Export folder as a COLMAP dataset in PostShot / LichtFeld Studio / gsplat / Brush,
/// or as a Nerfstudio dataset (transforms.json).
enum ProjectExporter {

    struct Summary {
        let directory: URL
        let imageCount: Int
        let pointCount: Int
    }

    enum ExportError: LocalizedError {
        case noScans
        var errorDescription: String? { "This project has no scans with frames to export." }
    }

    static func export(_ project: Project, progress: @escaping (String) -> Void) throws -> Summary {
        let fm = FileManager.default
        let scans = project.scans().filter { $0.frameCount > 0 }
        guard !scans.isEmpty else { throw ExportError.noScans }

        let out = project.exportDirectory
        try? fm.removeItem(at: out)
        let imagesDir = out.appendingPathComponent("images", isDirectory: true)
        let depthDir = out.appendingPathComponent("depth", isDirectory: true)
        let confDir = out.appendingPathComponent("confidence", isDirectory: true)
        let sparseDir = out.appendingPathComponent("sparse/0", isDirectory: true)
        for dir in [imagesDir, depthDir, confDir, sparseDir] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        var nsFrames: [[String: Any]] = []
        var firstCamera: [String: Any]?
        var cameraLines: [String] = []
        var imageLines: [String] = []
        var cameraRecords = Data()
        var imageRecords = Data()

        // ARKit/OpenGL camera (x right, y up, looks -z)  ->  OpenCV/COLMAP camera (x right, y down, looks +z)
        let flipYZ = simd_double4x4(diagonal: SIMD4<Double>(1, -1, -1, 1))

        for (scanIndex, scan) in scans.enumerated() {
            progress("Copying scan \(scanIndex + 1) of \(scans.count)…")
            guard let frames = ScanWriter.loadFrames(in: scan.url) else { continue }
            let prefix = String(format: "s%02d_", scanIndex + 1)

            for f in frames {
                guard let filePath = f["file_path"] as? String,
                      let rows = f["transform_matrix"] as? [[Double]], rows.count == 4,
                      rows.allSatisfy({ $0.count == 4 }),
                      let fx = f["fl_x"] as? Double, let fy = f["fl_y"] as? Double,
                      let cx = f["cx"] as? Double, let cy = f["cy"] as? Double,
                      let width = f["w"] as? Int, let height = f["h"] as? Int else { continue }

                // Images: copyItem clones on APFS, so this costs almost no extra storage.
                let imageName = prefix + (filePath as NSString).lastPathComponent
                try fm.copyItem(at: scan.url.appendingPathComponent(filePath), to: imagesDir.appendingPathComponent(imageName))

                var nf: [String: Any] = [
                    "file_path": "images/" + imageName,
                    "transform_matrix": rows,
                    "fl_x": fx, "fl_y": fy, "cx": cx, "cy": cy, "w": width, "h": height
                ]
                if let dp = f["depth_file_path"] as? String {
                    let dn = prefix + (dp as NSString).lastPathComponent
                    if (try? fm.copyItem(at: scan.url.appendingPathComponent(dp), to: depthDir.appendingPathComponent(dn))) != nil {
                        nf["depth_file_path"] = "depth/" + dn
                    }
                }
                if let cp = f["confidence_file_path"] as? String {
                    let cn = prefix + (cp as NSString).lastPathComponent
                    if (try? fm.copyItem(at: scan.url.appendingPathComponent(cp), to: confDir.appendingPathComponent(cn))) != nil {
                        nf["confidence_file_path"] = "confidence/" + cn
                    }
                }
                nsFrames.append(nf)
                if firstCamera == nil {
                    firstCamera = ["fl_x": fx, "fl_y": fy, "cx": cx, "cy": cy, "w": width, "h": height]
                }

                // COLMAP pose: world-to-camera in OpenCV convention.
                let id = nsFrames.count
                let c2w = simd_double4x4(rows: rows.map { SIMD4<Double>($0[0], $0[1], $0[2], $0[3]) })
                let w2c = (c2w * flipYZ).inverse
                let R = simd_double3x3(columns: (
                    SIMD3<Double>(w2c.columns.0.x, w2c.columns.0.y, w2c.columns.0.z),
                    SIMD3<Double>(w2c.columns.1.x, w2c.columns.1.y, w2c.columns.1.z),
                    SIMD3<Double>(w2c.columns.2.x, w2c.columns.2.y, w2c.columns.2.z)))
                var q = simd_quatd(R).normalized
                if q.real < 0 { q = simd_quatd(real: -q.real, imag: -q.imag) }
                let t = SIMD3<Double>(w2c.columns.3.x, w2c.columns.3.y, w2c.columns.3.z)

                cameraLines.append("\(id) PINHOLE \(width) \(height) \(fx) \(fy) \(cx) \(cy)")
                imageLines.append("\(id) \(q.real) \(q.imag.x) \(q.imag.y) \(q.imag.z) \(t.x) \(t.y) \(t.z) \(id) \(imageName)")
                imageLines.append("")   // no 2D observations

                cameraRecords.appendLE(Int32(id))
                cameraRecords.appendLE(Int32(1))            // PINHOLE
                cameraRecords.appendLE(UInt64(width))
                cameraRecords.appendLE(UInt64(height))
                for p in [fx, fy, cx, cy] { cameraRecords.appendLE(p) }

                imageRecords.appendLE(Int32(id))
                for v in [q.real, q.imag.x, q.imag.y, q.imag.z, t.x, t.y, t.z] { imageRecords.appendLE(v) }
                imageRecords.appendLE(Int32(id))            // camera id
                imageRecords.append(contentsOf: Array(imageName.utf8))
                imageRecords.append(0)
                imageRecords.appendLE(UInt64(0))            // number of 2D points
            }
        }
        guard !nsFrames.isEmpty else { throw ExportError.noScans }

        // Cameras + images
        progress("Writing camera poses…")
        var camerasBin = Data(); camerasBin.appendLE(UInt64(nsFrames.count)); camerasBin.append(cameraRecords)
        var imagesBin = Data(); imagesBin.appendLE(UInt64(nsFrames.count)); imagesBin.append(imageRecords)
        try camerasBin.write(to: sparseDir.appendingPathComponent("cameras.bin"))
        try imagesBin.write(to: sparseDir.appendingPathComponent("images.bin"))

        let camerasTxt = "# Camera list with one line of data per camera:\n#   CAMERA_ID, MODEL, WIDTH, HEIGHT, PARAMS[]\n# Number of cameras: \(nsFrames.count)\n"
            + cameraLines.joined(separator: "\n") + "\n"
        let imagesTxt = "# Image list with two lines of data per image:\n#   IMAGE_ID, QW, QX, QY, QZ, TX, TY, TZ, CAMERA_ID, NAME\n#   POINTS2D[] as (X, Y, POINT3D_ID)\n# Number of images: \(nsFrames.count)\n"
            + imageLines.joined(separator: "\n") + "\n"
        try camerasTxt.write(to: sparseDir.appendingPathComponent("cameras.txt"), atomically: true, encoding: .utf8)
        try imagesTxt.write(to: sparseDir.appendingPathComponent("images.txt"), atomically: true, encoding: .utf8)

        // Points (streamed, so millions of points don't need to sit in memory at once)
        progress("Merging point clouds…")
        let plyURLs = scans
            .map { $0.url.appendingPathComponent(ScanWriter.pointsFileName) }
            .filter { fm.fileExists(atPath: $0.path) }
        let total = plyURLs.reduce(0) { $0 + (PointCloudIO.vertexCount(of: $1) ?? 0) }

        let plyURL = out.appendingPathComponent("sparse_pc.ply")
        let ptsBinURL = sparseDir.appendingPathComponent("points3D.bin")
        let ptsTxtURL = sparseDir.appendingPathComponent("points3D.txt")
        for url in [plyURL, ptsBinURL, ptsTxtURL] { fm.createFile(atPath: url.path, contents: nil) }
        let plyHandle = try FileHandle(forWritingTo: plyURL)
        let binHandle = try FileHandle(forWritingTo: ptsBinURL)
        let txtHandle = try FileHandle(forWritingTo: ptsTxtURL)
        defer {
            try? plyHandle.close()
            try? binHandle.close()
            try? txtHandle.close()
        }

        try plyHandle.write(contentsOf: PointCloudIO.header(count: total))
        var binHeader = Data(); binHeader.appendLE(UInt64(total))
        try binHandle.write(contentsOf: binHeader)
        try txtHandle.write(contentsOf: Data("# 3D point list with one line of data per point:\n#   POINT3D_ID, X, Y, Z, R, G, B, ERROR, TRACK[] as (IMAGE_ID, POINT2D_IDX)\n# Number of points: \(total)\n".utf8))

        var written = 0
        for url in plyURLs where written < total {
            var plyChunk = Data(), binChunk = Data(), txtChunk = ""
            func flush() throws {
                try plyHandle.write(contentsOf: plyChunk)
                try binHandle.write(contentsOf: binChunk)
                try txtHandle.write(contentsOf: Data(txtChunk.utf8))
                plyChunk.removeAll(keepingCapacity: true)
                binChunk.removeAll(keepingCapacity: true)
                txtChunk = ""
            }
            for p in PointCloudIO.readPLY(url: url) {
                guard written < total else { break }
                written += 1
                PointCloudIO.append(p, to: &plyChunk)

                binChunk.appendLE(UInt64(written))
                binChunk.appendLE(Double(p.x)); binChunk.appendLE(Double(p.y)); binChunk.appendLE(Double(p.z))
                binChunk.append(p.r); binChunk.append(p.g); binChunk.append(p.b)
                binChunk.appendLE(Double(0))                // reprojection error
                binChunk.appendLE(UInt64(0))                // track length

                txtChunk += "\(written) \(p.x) \(p.y) \(p.z) \(p.r) \(p.g) \(p.b) 0\n"
                if binChunk.count > 4_000_000 { try flush() }
            }
            try flush()
        }

        // Nerfstudio transforms.json
        progress("Writing transforms.json…")
        var json: [String: Any] = firstCamera ?? [:]
        json["camera_model"] = "OPENCV"
        json["k1"] = 0.0; json["k2"] = 0.0; json["p1"] = 0.0; json["p2"] = 0.0
        json["depth_unit_scale_factor"] = 0.001
        json["frames"] = nsFrames
        json["capture_app"] = "PaintingScan 0.2"
        if total > 0 { json["ply_file_path"] = "sparse_pc.ply" }
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: out.appendingPathComponent("transforms.json"))

        let readme = """
        PaintingScan export – \(project.name)
        \(nsFrames.count) images from \(scans.count) scan(s), \(total) LiDAR points.

        COLMAP dataset (PostShot, LichtFeld Studio, gsplat, Brush): images/ + sparse/0/
        Nerfstudio dataset: transforms.json (+ depth/ in millimetres, sparse_pc.ply)

        Camera poses come directly from ARKit tracking – no COLMAP / SfM step is needed.
        Images are in the camera sensor's landscape orientation; intrinsics match.
        """
        try readme.write(to: out.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)

        return Summary(directory: out, imageCount: nsFrames.count, pointCount: written)
    }
}
