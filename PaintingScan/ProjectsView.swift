import SwiftUI
import UIKit

/// Projects: create / open / delete, list scans, export the merged dataset.
struct ProjectsView: View {
    @EnvironmentObject var capture: CaptureManager
    @Environment(\.dismiss) private var dismiss
    @State private var projects: [Project] = []
    @State private var showNew = false
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(projects) { project in
                        NavigationLink(value: project) {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(project.name).font(.headline)
                                    Text("\(project.scans().count) scans").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if capture.project == project {
                                    Text("OPEN").font(.caption.bold()).foregroundStyle(.green)
                                }
                            }
                        }
                    }
                } footer: {
                    Text("A project holds several scans of the same painting. They share one coordinate system and are merged on export.")
                }
            }
            .navigationTitle("Projects")
            .navigationDestination(for: Project.self) { project in
                ProjectDetailView(project: project,
                                  onOpen: { capture.openProject(project); dismiss() },
                                  onDeleted: { reload() })
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { newName = "Painting \(projects.count + 1)"; showNew = true } label: {
                        Label("New project", systemImage: "plus")
                    }
                }
            }
            .alert("New project", isPresented: $showNew) {
                TextField("Name", text: $newName)
                Button("Create") {
                    if let p = try? ProjectStore.create(name: newName) {
                        capture.openProject(p)
                        dismiss()
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
            .onAppear { reload() }
        }
    }

    private func reload() { projects = ProjectStore.list() }
}

struct ProjectDetailView: View {
    @EnvironmentObject var capture: CaptureManager
    @Environment(\.dismiss) private var dismiss
    let project: Project
    let onOpen: () -> Void
    let onDeleted: () -> Void

    @State private var scans: [ScanInfo] = []
    @State private var exportProgress: String?
    @State private var shareURL: URL?
    @State private var errorMessage: String?
    @State private var confirmDelete = false

    var body: some View {
        List {
            Section {
                Button(action: onOpen) {
                    Label(capture.project == project ? "Continue scanning" : "Open for scanning", systemImage: "camera.viewfinder")
                }
            }
            Section("Scans (\(scans.count))") {
                if scans.isEmpty { Text("No scans yet.").foregroundStyle(.secondary) }
                ForEach(scans) { scan in
                    VStack(alignment: .leading) {
                        Text(scan.name).font(.headline)
                        Text("\(scan.frameCount) frames · \(scan.pointCount.formatted()) points")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .onDelete { offsets in
                    offsets.map { scans[$0] }.forEach(project.deleteScan)
                    scans = project.scans()
                    if capture.project == project { capture.reloadHistory() }
                }
                .deleteDisabled(capture.isRecording)
            }
            Section {
                Button { export() } label: {
                    Label("Export for PostShot / LichtFeld Studio / Nerfstudio", systemImage: "square.and.arrow.up")
                }
                .disabled(scans.isEmpty || exportProgress != nil || capture.isRecording)
            } header: {
                Text("Export")
            } footer: {
                Text("Merges all scans into one dataset: images, COLMAP sparse/0 (cameras, images, points3D – no COLMAP/SfM run needed), transforms.json and sparse_pc.ply. The Export folder is also visible in the Files app.")
            }
            Section {
                Button("Delete project", role: .destructive) { confirmDelete = true }
                    .disabled(capture.isRecording)
            }
        }
        .navigationTitle(project.name)
        .overlay {
            if let p = exportProgress {
                ProgressView(p).padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .sheet(item: $shareURL) { url in ShareSheet(items: [url]) }
        .alert("Export failed", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
        .confirmationDialog("Delete \(project.name) and all its scans?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                let wasOpen = capture.project == project
                ProjectStore.delete(project)
                if wasOpen { capture.openDefaultProject() }
                onDeleted()
                dismiss()
            }
        }
        .onAppear { scans = project.scans() }
    }

    private func export() {
        exportProgress = "Preparing…"
        let p = project
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let summary = try ProjectExporter.export(p) { message in
                    DispatchQueue.main.async { exportProgress = message }
                }
                DispatchQueue.main.async { exportProgress = "Compressing \(summary.imageCount) images…" }
                let zip = try ProjectStore.zip(summary.directory, name: p.name + "_export")
                DispatchQueue.main.async {
                    exportProgress = nil
                    shareURL = zip
                }
            } catch {
                DispatchQueue.main.async {
                    exportProgress = nil
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

extension URL: Identifiable {
    public var id: String { absoluteString }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
