//
//  UsageStatisticsView.swift
//  contextgo
//
//  Token 使用统计视图 - 高级感半屏 Sheet
//

import SwiftUI
import Charts

struct UsageStatisticsView: View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var viewModel: UsageStatisticsViewModel

    init(client: OpenClawClient, sessionKey: String) {
        _viewModel = StateObject(wrappedValue: UsageStatisticsViewModel(client: client, sessionKey: sessionKey))
    }

    var body: some View {
        NavigationView {
            ZStack {
                // Background
                (colorScheme == .dark ? Color.black : Color(.systemGroupedBackground))
                    .ignoresSafeArea()

                if viewModel.isLoading {
                    ProgressView("加载中...")
                        .tint(.blue)
                } else if let error = viewModel.errorMessage {
                    errorView(error)
                } else if let data = viewModel.usageData {
                    if hasNoUsageData(data) {
                        emptyUsageView
                    } else {
                        contentView(data)
                    }
                }
            }
            .navigationTitle("Token 统计")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("完成") {
                        dismiss()
                    }
                    .fontWeight(.medium)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task {
            await viewModel.loadUsageData()
        }
    }

    // MARK: - Content View

    private var emptyUsageView: some View {
        VStack(spacing: 16) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 46, weight: .semibold))
                .foregroundColor(.secondary)

            Text("暂无 Token 消耗数据")
                .font(.headline)

            Text("当前会话还没有产生统计数据。\n发送第一条消息后，这里会自动显示消耗趋势。")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)

            Button("我知道了") {
                dismiss()
            }
            .font(.subheadline)
            .fontWeight(.medium)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(Color.blue.opacity(0.12))
            .foregroundColor(.blue)
            .cornerRadius(10)
        }
    }

    private func hasNoUsageData(_ data: UsageCostPayload) -> Bool {
        let dailyTotalTokens = data.daily.reduce(0) { $0 + $1.totalTokens }
        return data.totals.totalTokens == 0 &&
            dailyTotalTokens == 0 &&
            data.totals.totalCost == 0
    }

    @ViewBuilder
    private func contentView(_ data: UsageCostPayload) -> some View {
        ScrollView {
            VStack(spacing: 24) {
                // 总计卡片
                totalsCard(data.totals)

                // 今日统计 - 取最后一个（最新的）
                if let today = data.daily.last {
                    todayCard(today)
                }

                // Token 使用趋势图
                if !data.daily.isEmpty {
                    trendChartCard(data.daily)
                }

                // 每日明细列表
                dailyListCard(data.daily)
            }
            .padding()
        }
        .scrollIndicators(.hidden)
    }

    // MARK: - Totals Card

    @ViewBuilder
    private func totalsCard(_ totals: UsageTotals) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "chart.bar.fill")
                    .foregroundColor(.blue)
                Text("总计统计")
                    .font(.headline)
                    .foregroundColor(colorScheme == .dark ? .white : .primary)
                Spacer()
                Text("最近 31 天")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Token 总量
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("总 Tokens")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Text(totals.formattedTokens(totals.totalTokens))
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(.blue)
                }
                Spacer()
                if totals.totalCost > 0 {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("总费用")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Text(totals.formattedCost(totals.totalCost))
                            .font(.title2)
                            .fontWeight(.bold)
                            .foregroundColor(.green)
                    }
                }
            }

            Divider()

            // 详细统计
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                GridRow {
                    tokenStatItem("输入", totals.input, totals.inputCost ?? 0, color: .purple)
                    tokenStatItem("输出", totals.output, totals.outputCost ?? 0, color: .orange)
                }
                GridRow {
                    tokenStatItem("缓存读", totals.cacheRead, totals.cacheReadCost ?? 0, color: .cyan)
                    tokenStatItem("缓存写", totals.cacheWrite, totals.cacheWriteCost ?? 0, color: .pink)
                }
            }
        }
        .padding()
        .background(cardBackground)
        .cornerRadius(16)
        .shadow(color: Color.black.opacity(0.05), radius: 8, x: 0, y: 2)
    }

    // MARK: - Today Card

    @ViewBuilder
    private func todayCard(_ today: DailyUsage) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "calendar.badge.clock")
                    .foregroundColor(.green)
                Text("今日使用")
                    .font(.headline)
                    .foregroundColor(colorScheme == .dark ? .white : .primary)
                Spacer()
                Text(today.date)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // 合并为一行：数字 + tokens（样式区分）
            let formattedValue = UsageTotals(
                input: 0, output: 0, cacheRead: 0, cacheWrite: 0,
                totalTokens: today.totalTokens,
                totalCost: 0, inputCost: nil, outputCost: nil,
                cacheReadCost: nil, cacheWriteCost: nil, missingCostEntries: 0
            ).formattedTokens(today.totalTokens)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(formattedValue)
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(.blue)

                Text("tokens")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(cardBackground)
        .cornerRadius(16)
        .shadow(color: Color.black.opacity(0.05), radius: 8, x: 0, y: 2)
    }

    // MARK: - Trend Chart Card

    @ViewBuilder
    private func trendChartCard(_ daily: [DailyUsage]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .foregroundColor(.orange)
                Text("使用趋势")
                    .font(.headline)
                    .foregroundColor(colorScheme == .dark ? .white : .primary)
            }

            if #available(iOS 16.0, *) {
                // Take last 14 days and ensure chronological order (oldest to newest)
                let chartData = Array(daily.suffix(14))

                Chart(chartData) { day in
                    BarMark(
                        x: .value("日期", day.date),  // Use YYYY-MM-DD for proper sorting
                        y: .value("Tokens", day.totalTokens)
                    )
                    .foregroundStyle(.blue.gradient)
                }
                .frame(height: 200)
                .chartXAxis {
                    AxisMarks(values: .stride(by: 2)) { value in
                        AxisValueLabel {
                            // Display as MM/DD format
                            if let dateStr = value.as(String.self) {
                                let components = dateStr.split(separator: "-")
                                if components.count == 3 {
                                    Text("\(components[1])/\(components[2])")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text(dateStr)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                // Remove reversed parameter as it's not needed with YYYY-MM-DD format
                .chartYAxis {
                    AxisMarks { value in
                        AxisValueLabel {
                            if let intValue = value.as(Int.self) {
                                Text(formatTokensShort(intValue))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } else {
                Text("需要 iOS 16+ 支持图表")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(height: 200)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding()
        .background(cardBackground)
        .cornerRadius(16)
        .shadow(color: Color.black.opacity(0.05), radius: 8, x: 0, y: 2)
    }

    // MARK: - Daily List Card

    @ViewBuilder
    private func dailyListCard(_ daily: [DailyUsage]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "list.bullet.rectangle")
                    .foregroundColor(.purple)
                Text("每日明细")
                    .font(.headline)
                    .foregroundColor(colorScheme == .dark ? .white : .primary)
            }

            VStack(spacing: 1) {
                ForEach(daily.prefix(10).reversed()) { day in
                    dailyRow(day)
                }
            }
        }
        .padding()
        .background(cardBackground)
        .cornerRadius(16)
        .shadow(color: Color.black.opacity(0.05), radius: 8, x: 0, y: 2)
    }

    @ViewBuilder
    private func dailyRow(_ day: DailyUsage) -> some View {
        HStack {
            // 左边：日期
            Text(day.date)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(colorScheme == .dark ? .white : .primary)

            Spacer()

            // 右边：Token 消耗（样式区分）
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("\(day.totalTokens)")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(colorScheme == .dark ? .white : .primary)

                Text("tokens")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .background(colorScheme == .dark ? Color(.systemGray6).opacity(0.3) : Color(.systemBackground))
    }

    // MARK: - Token Stat Item

    @ViewBuilder
    private func tokenStatItem(_ title: String, _ tokens: Int, _ cost: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Text(UsageTotals(
                input: 0, output: 0, cacheRead: 0, cacheWrite: 0,
                totalTokens: tokens,
                totalCost: 0, inputCost: nil, outputCost: nil,
                cacheReadCost: nil, cacheWriteCost: nil, missingCostEntries: 0
            ).formattedTokens(tokens))
                .font(.callout)
                .fontWeight(.semibold)
                .foregroundColor(colorScheme == .dark ? .white : .primary)

            if cost > 0 {
                Text(UsageTotals(
                    input: 0, output: 0, cacheRead: 0, cacheWrite: 0,
                    totalTokens: 0, totalCost: cost,
                    inputCost: nil, outputCost: nil, cacheReadCost: nil, cacheWriteCost: nil, missingCostEntries: 0
                ).formattedCost(cost))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Error View

    @ViewBuilder
    private func errorView(_ error: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundColor(.orange)

            Text("加载失败")
                .font(.headline)

            Text(error)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button(action: {
                Task {
                    await viewModel.loadUsageData()
                }
            }) {
                Label("重试", systemImage: "arrow.clockwise")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Color.blue)
                    .cornerRadius(10)
            }
        }
    }

    // MARK: - Helpers

    private var cardBackground: some View {
        colorScheme == .dark
            ? Color(.systemGray6).opacity(0.5)
            : Color(.systemBackground)
    }

    private func formatTokensShort(_ tokens: Int) -> String {
        if tokens >= 1_000_000 {
            return "\(tokens / 1_000_000)M"
        } else if tokens >= 1_000 {
            return "\(tokens / 1_000)K"
        } else {
            return "\(tokens)"
        }
    }
}

// MARK: - ViewModel

@MainActor
class UsageStatisticsViewModel: ObservableObject {
    @Published var usageData: UsageCostPayload?
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?

    private let client: OpenClawClient
    private let sessionKey: String
    private static let emptyUsagePayload = UsageCostPayload(
        updatedAt: Int64(Date().timeIntervalSince1970 * 1000),
        days: 0,
        daily: [],
        totals: UsageTotals(
            input: 0,
            output: 0,
            cacheRead: 0,
            cacheWrite: 0,
            totalTokens: 0,
            totalCost: 0,
            inputCost: nil,
            outputCost: nil,
            cacheReadCost: nil,
            cacheWriteCost: nil,
            missingCostEntries: 0
        )
    )

    init(client: OpenClawClient, sessionKey: String) {
        self.client = client
        self.sessionKey = sessionKey
    }

    func loadUsageData() async {
        isLoading = true
        errorMessage = nil

        do {
            usageData = try await client.fetchSessionUsageCost(sessionKey: sessionKey)
            isLoading = false
            return
        } catch {
            print("[UsageStatistics] Session usage failed for key \(sessionKey): \(error)")

            do {
                usageData = try await client.fetchUsageCost()
            } catch {
                if case let OpenClawError.requestFailed(message) = error,
                   isNoUsageDataError(message) {
                    usageData = Self.emptyUsagePayload
                } else {
                    errorMessage = "无法加载统计数据: \(error.localizedDescription)"
                    print("[UsageStatistics] Global usage fallback failed: \(error)")
                }
            }
        }

        isLoading = false
    }

    private func isNoUsageDataError(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return normalized.contains("invalid session") ||
            normalized.contains("not found") ||
            normalized.contains("no sessions") ||
            normalized.contains("failed to fetch session usage")
    }
}
