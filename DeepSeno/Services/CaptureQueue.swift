import Foundation
import SwiftData
import os

let captureLog = OSLog(subsystem: "com.enmooy.deepseno", category: "CaptureQueue")

@Observable
class CaptureQueue: @unchecked Sendable {
    var pendingCount: Int = 0
    var failedCount: Int = 0
    var isProcessing: Bool = false

    private var modelContext: ModelContext?
    private var currentAPIClient: APIClient?
    private var processingTask: Task<Void, Never>?

    func setModelContext(_ context: ModelContext) {
        self.modelContext = context
        refreshCounts()
    }

    func add(type: String, localPath: String, fileName: String, textContent: String? = nil, bookmarks: String? = nil) {
        guard let context = modelContext else {
            print("[CaptureQueue] add() failed: modelContext is nil")
            return
        }
        let item = CaptureItem(
            type: type,
            localPath: localPath,
            fileName: fileName,
            textContent: textContent
        )
        item.bookmarksJSON = bookmarks
        context.insert(item)
        saveContext(context, reason: "add(\(type))")
        refreshCounts()
        print("[CaptureQueue] add() type=\(type), pending=\(pendingCount), hasAPI=\(currentAPIClient != nil)")

        // Auto-process if connected
        if let api = currentAPIClient {
            Task {
                await processQueue(apiClient: api)
            }
        }
    }

    func addGroup(type: String, localPaths: [String], fileNames: [String], groupName: String) {
        guard let context = modelContext else {
            print("[CaptureQueue] addGroup() failed: modelContext is nil")
            return
        }
        let pathsJSON = (try? JSONEncoder().encode(localPaths)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

        let item = CaptureItem(
            type: type,
            localPath: localPaths.first ?? "",
            fileName: groupName
        )
        item.groupPaths = pathsJSON
        item.groupName = groupName
        context.insert(item)
        saveContext(context, reason: "addGroup(\(type))")
        refreshCounts()
        print("[CaptureQueue] addGroup() type=\(type), count=\(localPaths.count), group=\(groupName)")

        if let api = currentAPIClient {
            Task { await processQueue(apiClient: api) }
        }
    }

    func processQueue(apiClient: APIClient) async {
        os_log(.error, log: captureLog, "processQueue START")
        processingTask?.cancel()
        currentAPIClient = apiClient

        let task = Task { [weak self] in
            guard let self else { return }
            await self.runProcessLoop(apiClient: apiClient)
        }
        processingTask = task
        await task.value
        os_log(.error, log: captureLog, "processQueue DONE")
    }

    private func runProcessLoop(apiClient: APIClient) async {
        guard let context = modelContext else {
            print("[CaptureQueue] processQueue: no modelContext")
            return
        }

        isProcessing = true
        print("[CaptureQueue] processQueue started")
        defer {
            isProcessing = false
            refreshCounts()
        }

        let descriptor = FetchDescriptor<CaptureItem>(
            predicate: #Predicate { $0.status == "pending" || $0.status == "uploading" },
            sortBy: [SortDescriptor(\.createdAt)]
        )

        guard let items = try? context.fetch(descriptor) else { return }
        print("[CaptureQueue] found \(items.count) items to process")

        for item in items {
            guard !Task.isCancelled else {
                print("[CaptureQueue] task cancelled, stopping loop")
                return
            }

            do {
                item.status = "uploading"
                let itemType = item.type
                print("[CaptureQueue] processing: type=\(itemType), file=\(item.fileName)")

                if itemType == "text", let content = item.textContent {
                    try await apiClient.createNote(content: content)
                    print("[CaptureQueue] text note sent OK")
                } else if let pathsJSON = item.groupPaths,
                          let gName = item.groupName,
                          let pathsData = pathsJSON.data(using: .utf8),
                          let paths = try? JSONDecoder().decode([String].self, from: pathsData) {
                    // Multi-image group upload
                    let fileURLs = paths.map { URL(fileURLWithPath: $0) }
                    let fNames = paths.enumerated().map { (i, _) in String(format: "%02d.jpg", i + 1) }
                    let allExist = fileURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
                    guard allExist else {
                        print("[CaptureQueue] some group files missing, marking failed")
                        item.status = "failed"
                        saveContext(context, reason: "group-missing")
                        continue
                    }
                    _ = try await apiClient.uploadImages(fileURLs: fileURLs, fileNames: fNames, groupName: gName)
                    print("[CaptureQueue] image group uploaded OK (\(paths.count) images)")
                } else {
                    let fileURL = URL(fileURLWithPath: item.localPath)
                    guard FileManager.default.fileExists(atPath: item.localPath) else {
                        os_log(.error, log: captureLog, "file missing: %{public}@", item.localPath)
                        item.status = "failed"
                        saveContext(context, reason: "file-missing")
                        continue
                    }
                    os_log(.error, log: captureLog, "calling upload: %{public}@ size=%lld", item.fileName, (try? FileManager.default.attributesOfItem(atPath: item.localPath)[.size] as? Int64) ?? -1)
                    _ = try await apiClient.upload(
                        fileURL: fileURL,
                        fileName: item.fileName,
                        bookmarks: item.bookmarksJSON
                    )
                    os_log(.error, log: captureLog, "upload OK: %{public}@", item.fileName)
                }

                context.delete(item)
                saveContext(context, reason: "upload-success")
            } catch {
                os_log(.error, log: captureLog, "upload FAILED: %{public}@ retries=%d", item.fileName, item.retries)
                item.retries += 1
                if item.retries >= 3 {
                    item.status = "failed"
                } else {
                    item.status = "pending"
                }
                saveContext(context, reason: "upload-error")

                // Short backoff, but check generation to allow cancel
                let delay = min(Double(2 * (1 << item.retries)), 10.0)
                try? await Task.sleep(for: .seconds(delay))
            }
        }
        print("[CaptureQueue] processQueue done")
    }

    func retryAll() {
        guard let context = modelContext else { return }
        let descriptor = FetchDescriptor<CaptureItem>(
            predicate: #Predicate { $0.status == "failed" }
        )
        if let items = try? context.fetch(descriptor) {
            for item in items {
                item.status = "pending"
                item.retries = 0
            }
            saveContext(context, reason: "retryAll")
            refreshCounts()
        }
    }

    /// Reset failed items AND trigger upload (mirrors Android retryAndProcess).
    func retryAndProcess() {
        os_log(.error, log: captureLog, "retryAndProcess called")
        guard let context = modelContext else { os_log(.error, log: captureLog, "no context"); return }
        let descriptor = FetchDescriptor<CaptureItem>(
            predicate: #Predicate { $0.status == "failed" }
        )
        if let items = try? context.fetch(descriptor) {
            for item in items {
                item.status = "pending"
                item.retries = 0
            }
            saveContext(context, reason: "retryAndProcess")
            refreshCounts()
            os_log(.error, log: captureLog, "retryAndProcess reset %d items", items.count)
        }
        let hasApi = currentAPIClient != nil
        os_log(.error, log: captureLog, "retryAndProcess hasApi=%{public}@", String(hasApi))
        if let api = currentAPIClient {
            os_log(.error, log: captureLog, "retryAndProcess calling processQueue")
            Task { await processQueue(apiClient: api) }
        }
    }

    func clearAll() {
        guard let context = modelContext else { return }
        let descriptor = FetchDescriptor<CaptureItem>()
        if let items = try? context.fetch(descriptor) {
            for item in items { context.delete(item) }
            saveContext(context, reason: "clearAll")
            refreshCounts()
        }
    }

    private func saveContext(_ context: ModelContext, reason: String) {
        do {
            try context.save()
        } catch {
            print("[CaptureQueue] save failed (\(reason)): \(error)")
        }
    }

    func getItems() -> [CaptureItem] {
        guard let context = modelContext else { return [] }
        let descriptor = FetchDescriptor<CaptureItem>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    private func refreshCounts() {
        guard let context = modelContext else { return }
        let pending = FetchDescriptor<CaptureItem>(
            predicate: #Predicate { $0.status == "pending" || $0.status == "uploading" }
        )
        let failed = FetchDescriptor<CaptureItem>(
            predicate: #Predicate { $0.status == "failed" }
        )
        pendingCount = (try? context.fetchCount(pending)) ?? 0
        failedCount = (try? context.fetchCount(failed)) ?? 0
    }
}
