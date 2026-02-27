//
//  CronJobsView.swift
//  contextgo
//
//  Cron 定时任务管理视图
//

import SwiftUI

struct CronJobsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var viewModel: CronJobsViewModel

    init(client: OpenClawClient) {
        _viewModel = StateObject(wrappedValue: CronJobsViewModel(client: client))
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
                } else {
                    contentView
                }
            }
            .navigationTitle("定时任务")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") {
                        dismiss()
                    }
                    .fontWeight(.medium)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task {
            await viewModel.loadJobs()
        }
        .sheet(item: $viewModel.selectedJob) { job in
            CronJobDetailView(job: job, viewModel: viewModel)
        }
        // ✅ NEW: Success toast/alert
        .alert("成功", isPresented: Binding(
            get: { viewModel.successMessage != nil },
            set: { if !$0 { viewModel.successMessage = nil } }
        )) {
            Button("确定", role: .cancel) {
                viewModel.successMessage = nil
            }
        } message: {
            Text(viewModel.successMessage ?? "操作成功")
        }
    }

    // MARK: - Content View

    @ViewBuilder
    private var contentView: some View {
        VStack(spacing: 0) {
            // Status card
            if let status = viewModel.status {
                statusCard(status)
                    .padding()
            }

            // Jobs list
            if viewModel.jobs.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(viewModel.jobs) { job in
                            CronJobCard(job: job) {
                                viewModel.selectedJob = job
                            }
                        }
                    }
                    .padding()
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    // MARK: - Status Card

    @ViewBuilder
    private func statusCard(_ status: CronStatus) -> some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: status.enabled ? "clock.fill" : "clock.badge.xmark.fill")
                    .foregroundColor(status.enabled ? .green : .gray)
                Text("服务状态")
                    .font(.headline)
                Spacer()
                Text(status.enabled ? "运行中" : "已停止")
                    .font(.caption)
                    .foregroundColor(status.enabled ? .green : .gray)
            }

            HStack(spacing: 20) {
                statItem("总任务", "\(status.totalJobs)")
                Divider().frame(height: 30)
                statItem("启用", "\(status.activeJobs)")

                if let nextRun = status.nextRunDate {
                    Divider().frame(height: 30)
                    statItem("下次执行", timeString(nextRun))
                }
            }
        }
        .padding()
        .background(cardBackground)
        .cornerRadius(12)
    }

    @ViewBuilder
    private func statItem(_ title: String, _ value: String) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundColor(colorScheme == .dark ? .white : .primary)
        }
    }

    // MARK: - Empty State

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "message.badge.waveform.fill")
                .font(.system(size: 60))
                .foregroundColor(.blue)

            Text("暂无定时任务")
                .font(.headline)
                .foregroundColor(.primary)

            Text("你可以在对话框中直接告诉 AI\n你需要什么定时任务")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)

            Text("例如：每天凌晨2点帮我生成报告")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color(.systemGray6))
                .cornerRadius(8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    await viewModel.loadJobs()
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

    private func timeString(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Cron Job Card

struct CronJobCard: View {
    let job: CronJob
    let onTap: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(job.name)
                            .font(.headline)
                            .foregroundColor(colorScheme == .dark ? .white : .primary)

                        if let text = job.payload.text {
                            Text(text)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                        }
                    }

                    Spacer()

                    // Status indicator (always green for active jobs)
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                }

                Divider()

                HStack {
                    Label(job.scheduleDescription, systemImage: "calendar")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Spacer()

                    Text(job.schedule.tz)
                        .font(.caption)
                        .foregroundColor(.blue)
                }
            }
            .padding()
            .background(cardBackground)
            .cornerRadius(12)
        }
        .buttonStyle(.plain)
    }

    private var cardBackground: some View {
        colorScheme == .dark
            ? Color(.systemGray6).opacity(0.5)
            : Color(.systemBackground)
    }

    private func timeString(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Cron Job Detail View

struct CronJobDetailView: View {
    let job: CronJob
    @ObservedObject var viewModel: CronJobsViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var runs: [CronRunEntry] = []
    @State private var isLoadingRuns = false
    @State private var isExecuting = false  // ✅ NEW: Track execution state
    @State private var showSuccessAlert = false  // ✅ NEW: Show success feedback

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    // Job info card
                    VStack(alignment: .leading, spacing: 12) {
                        Text(job.name)
                            .font(.title3)
                            .fontWeight(.bold)

                        if let text = job.payload.text {
                            Text(text)
                                .font(.body)
                                .foregroundColor(.secondary)
                        }

                        Divider()

                        infoRow("执行时间", job.scheduleDescription)
                        infoRow("Cron 表达式", job.schedule.expr)
                        infoRow("时区", job.schedule.tz)
                        infoRow("Agent ID", job.agentId)
                        infoRow("Session Target", job.sessionTarget)
                        infoRow("创建时间", dateString(job.createdAt))
                        infoRow("更新时间", dateString(job.updatedAt))
                    }
                    .padding()
                    .background(cardBackground)
                    .cornerRadius(12)

                    // Actions
                    VStack(spacing: 12) {
                        Button(action: {
                            isExecuting = true
                            Task {
                                await viewModel.runJob(job.id)
                                isExecuting = false
                                if viewModel.successMessage != nil {
                                    showSuccessAlert = true
                                }
                            }
                        }) {
                            HStack {
                                if isExecuting {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                        .scaleEffect(0.8)
                                }
                                Label(isExecuting ? "执行中..." : "立即执行", systemImage: "play.fill")
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(isExecuting ? Color.blue.opacity(0.6) : Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                        }
                        .disabled(isExecuting)

                        Button(role: .destructive, action: {
                            Task {
                                await viewModel.removeJob(job.id)
                                dismiss()
                            }
                        }) {
                            Label("删除任务", systemImage: "trash.fill")
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.red.opacity(0.1))
                                .foregroundColor(.red)
                                .cornerRadius(10)
                        }
                    }

                    // Execution history
                    VStack(alignment: .leading, spacing: 12) {
                        Text("执行历史")
                            .font(.headline)

                        if isLoadingRuns {
                            HStack {
                                Spacer()
                                ProgressView()
                                    .padding()
                                Spacer()
                            }
                        } else if runs.isEmpty {
                            Text("暂无执行历史")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .padding()
                        } else {
                            ForEach(runs.prefix(5)) { run in
                                runRow(run)
                            }
                        }
                    }
                    .padding()
                    .background(cardBackground)
                    .cornerRadius(12)
                }
                .padding()
            }
            .scrollIndicators(.hidden)
            .navigationTitle("任务详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
        }
        .task {
            await loadRuns()
        }
        // ✅ NEW: Success alert
        .alert("成功", isPresented: $showSuccessAlert) {
            Button("确定", role: .cancel) {
                viewModel.successMessage = nil
            }
        } message: {
            Text(viewModel.successMessage ?? "操作成功")
        }
        // ✅ NEW: Error alert (reuse existing errorMessage)
        .alert("错误", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("确定", role: .cancel) {
                viewModel.errorMessage = nil
            }
        } message: {
            Text(viewModel.errorMessage ?? "未知错误")
        }
    }

    @ViewBuilder
    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline)
                .fontWeight(.medium)
        }
    }

    @ViewBuilder
    private func runRow(_ run: CronRunEntry) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(dateString(run.runAt))
                    .font(.caption)
                    .foregroundColor(.secondary)

                if let summary = run.summary {
                    Text(summary)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }

                if let duration = run.duration {
                    Text("耗时: \(String(format: "%.2f", duration))s")
                        .font(.caption2)
                        .foregroundColor(.secondary.opacity(0.7))
                }
            }

            Spacer()

            Label(run.isSuccess ? "成功" : "失败", systemImage: run.isSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.caption)
                .foregroundColor(run.isSuccess ? .green : .red)
        }
        .padding(.vertical, 4)
    }

    private func loadRuns() async {
        isLoadingRuns = true
        do {
            runs = try await viewModel.client.fetchCronRuns(jobId: job.id, limit: 5)
        } catch {
            print("Failed to load runs: \(error)")
        }
        isLoadingRuns = false
    }

    private var cardBackground: some View {
        colorScheme == .dark
            ? Color(.systemGray6).opacity(0.5)
            : Color(.systemBackground)
    }

    private func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

// MARK: - View Model

@MainActor
class CronJobsViewModel: ObservableObject {
    @Published var jobs: [CronJob] = []
    @Published var status: CronStatus?
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var successMessage: String?  // ✅ NEW: Success feedback
    @Published var selectedJob: CronJob?

    let client: OpenClawClient

    init(client: OpenClawClient) {
        self.client = client
    }

    func loadJobs() async {
        isLoading = true
        errorMessage = nil

        do {
            async let jobsFetch = client.fetchCronJobs(includeDisabled: true)
            async let statusFetch = client.fetchCronStatus()

            jobs = try await jobsFetch
            status = try await statusFetch
        } catch {
            errorMessage = "加载失败: \(error.localizedDescription)"
        }

        isLoading = false
    }

    func removeJob(_ id: String) async {
        do {
            try await client.removeCronJob(id: id)
            successMessage = "任务已删除"
            await loadJobs()
        } catch {
            errorMessage = "删除失败: \(error.localizedDescription)"
        }
    }

    func toggleJob(_ id: String, enabled: Bool) async {
        do {
            let patch = CronJobPatch(schedule: nil, enabled: enabled, action: nil)
            try await client.updateCronJob(id: id, patch: patch)
            successMessage = enabled ? "任务已启用" : "任务已禁用"
            await loadJobs()
        } catch {
            errorMessage = "更新失败: \(error.localizedDescription)"
        }
    }

    func runJob(_ id: String) async {
        do {
            try await client.runCronJob(id: id, mode: "force")
            successMessage = "任务执行成功"
            // Optionally refresh
        } catch {
            errorMessage = "执行失败: \(error.localizedDescription)"
        }
    }
}
