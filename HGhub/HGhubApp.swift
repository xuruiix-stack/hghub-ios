import SwiftUI

// MARK: - Entry (HGhub: vertical short-drama client, personal non-commercial use)

@main
struct HGhubApp: App {
    @StateObject private var store = AppStore.shared
    @StateObject private var api = API.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(store.theme == .dark ? .dark : .light)
                .task {
                    await api.boot()
                }
        }
    }
}

// AVPlayer imports for player views (kept here to avoid extra file)
import AVFoundation
