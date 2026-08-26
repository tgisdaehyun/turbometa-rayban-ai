/*
 * App Route Manager
 * 全局应用内路由 - 供快捷指令/App Intent 与 UI 入口统一触发页面跳转
 *
 * 使用进程内持久状态（pendingRoute）代替瞬时 NotificationCenter：
 * - 冷启动兜底：Intent 冷启动 App 时视图尚未创建，瞬时通知不会补发，
 *   常驻视图可在 onAppear 中消费 pendingRoute
 * - 路由全局生效：消费方为常驻的 MainTabView，任意 Tab 均可响应
 */

import SwiftUI

enum AppRoute {
    case liveAI
}

@MainActor
final class AppRouteManager: ObservableObject {
    static let shared = AppRouteManager()

    /// 待消费的路由；消费后必须清空，避免误触发
    @Published var pendingRoute: AppRoute?

    private init() {}

    /// 取出并清空待处理路由，保证一次性消费
    func consume() -> AppRoute? {
        let route = pendingRoute
        pendingRoute = nil
        return route
    }
}
