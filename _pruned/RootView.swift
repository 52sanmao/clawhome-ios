//
//  RootView.swift
//  contextgo
//
//  Root view — LoginView 负责认证状态和过渡动画
//

import SwiftUI

struct RootView: View {
    var body: some View {
        // LoginView 内部管理所有认证状态：
        //   未登录 → 显示粒子动画 + OAuth 登录按钮
        //   OAuth 成功 → 播放汇聚动画 → 进入 MainAppView
        //   已登录 → 直接进入 MainAppView（快速过渡）
        LoginView()
    }
}

#Preview {
    RootView()
}
