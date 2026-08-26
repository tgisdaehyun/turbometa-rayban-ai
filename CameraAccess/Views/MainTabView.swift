/*
 * Main Tab View
 * 主 Tab 导航视图
 */

import SwiftUI

struct MainTabView: View {
    @ObservedObject var streamViewModel: StreamSessionViewModel
    @ObservedObject var wearablesViewModel: WearablesViewModel
    @StateObject private var routeManager = AppRouteManager.shared

    @State private var selectedTab = 0
    @State private var showLiveAI = false

    // Read API Key from secure storage
    private var apiKey: String {
        APIKeyManager.shared.getAPIKey() ?? ""
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            // Home - Feature entry
            TurboMetaHomeView(streamViewModel: streamViewModel, wearablesViewModel: wearablesViewModel, apiKey: apiKey)
                .tabItem {
                    Label("tab.home".localized, systemImage: "house.fill")
                }
                .tag(0)

            // Records
            RecordsView()
                .tabItem {
                    Label("tab.records".localized, systemImage: "list.bullet.rectangle")
                }
                .tag(1)

            // Gallery
            GalleryView()
                .tabItem {
                    Label("tab.gallery".localized, systemImage: "photo.on.rectangle")
                }
                .tag(2)

            // Settings
            SettingsView(streamViewModel: streamViewModel, apiKey: apiKey)
                .tabItem {
                    Label("tab.settings".localized, systemImage: "person.fill")
                }
                .tag(3)
        }
        .accentColor(AppColors.primary)
        .onAppear {
            // 先注入依赖：会话启动前 LiveAIManager 必须持有 streamViewModel，
            // 避免冷启动时视图生命周期顺序导致误报 notInitialized
            LiveAIManager.shared.setStreamViewModel(streamViewModel)
            // 冷启动兜底：路由写入时视图尚未创建的场景（如 Intent 冷启动 App）
            if routeManager.consume() == .liveAI {
                showLiveAI = true
            }
        }
        .onChange(of: routeManager.pendingRoute) { _, route in
            // 前台实时路由：快捷指令或首页卡片触发
            guard route == .liveAI else { return }
            routeManager.pendingRoute = nil
            showLiveAI = true
        }
        .fullScreenCover(isPresented: $showLiveAI) {
            LiveAIView(streamViewModel: streamViewModel)
        }
    }
}
