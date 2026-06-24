import SwiftUI

@Observable
class SourcesViewModel: @unchecked Sendable {
    var recordings: [Recording] = []
    var searchResults: [SearchResult]?
    var searchQuery = ""
    var selectedFilter = "all" // all, audio, video, document, image
    var isLoading = false
    var selectedRecording: Recording?
    var errorMessage: String?

    var filteredRecordings: [Recording] {
        let list = recordings
        switch selectedFilter {
        case "audio": return list.filter { $0.mediaType == "audio" }
        case "video": return list.filter { $0.mediaType == "video" }
        case "document": return list.filter { ["pdf", "docx", "text"].contains($0.mediaType) }
        case "image": return list.filter { $0.mediaType == "image" }
        default: return list
        }
    }

    func loadRecordings(apiClient: APIClient) async {
        isLoading = true
        errorMessage = nil
        do {
            recordings = try await apiClient.getRecordings()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func search(apiClient: APIClient) async {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchResults = nil
            return
        }
        do {
            searchResults = try await apiClient.search(query: query)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
