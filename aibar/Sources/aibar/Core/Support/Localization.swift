import Foundation

/// Bilingual string table for the dashboard's UI chrome. Each function takes
/// the current language explicitly (read from `Environment.appLanguage` at
/// each call site) rather than relying on global state, since a picker change
/// must relabel every open view immediately.
enum L {
    static func noData(_ lang: AppLanguage) -> String { lang == .zh ? "暂无数据" : "No data" }
    static func remainingWord(_ lang: AppLanguage) -> String { lang == .zh ? "剩余" : "remaining" }

    static func weekdayLabels(_ lang: AppLanguage) -> [String] {
        lang == .zh ? ["一", "二", "三", "四", "五", "六", "日"] : ["M", "T", "W", "T", "F", "S", "S"]
    }
    static func heatmapHover(_ lang: AppLanguage, date: String, cost: String, tokens: String) -> String {
        lang == .zh ? "\(date)：\(cost) · \(tokens) token" : "\(date): \(cost) · \(tokens) tokens"
    }
    static func heatmapHint(_ lang: AppLanguage, days: Int) -> String {
        lang == .zh ? "近 \(days) 天" : "Last \(days) days"
    }
    static func heatmapTimelineHint(_ lang: AppLanguage, days: Int) -> String {
        lang == .zh
            ? "\(days)天 · token 深浅 · 今天有边框"
            : "\(days)d · token intensity · today outlined"
    }
    static func heatmapMarkerHover(
        _ lang: AppLanguage,
        date: String,
        markers: String
    ) -> String {
        lang == .zh ? "\(date)：\(markers)" : "\(date): \(markers)"
    }
    static func heatmapResetHover(
        _ lang: AppLanguage,
        date: String,
        count: Int,
        times: String,
        additionalMarkers: [String] = []
    ) -> String {
        let resetText = lang == .zh
            ? "\(date)：\(count) 次 reset 到期 · \(times)"
            : "\(date): \(count) reset \(count == 1 ? "expires" : "expire") · \(times)"
        guard !additionalMarkers.isEmpty else { return resetText }
        return resetText + " · " + additionalMarkers.joined(separator: " · ")
    }
    static func resetExpiryLegend(_ lang: AppLanguage) -> String {
        lang == .zh ? "重置 >10天" : "Reset >10d"
    }
    static func resetExpiryUrgentLegend(_ lang: AppLanguage) -> String {
        lang == .zh ? "重置 ≤10天" : "Reset ≤10d"
    }
    static func resetExpiryWithinDays(_ lang: AppLanguage, days: Int) -> String {
        if days == 0 { return lang == .zh ? "今天到期" : "Expires today" }
        return lang == .zh ? "\(days) 天内到期" : "Expires in \(days)d"
    }
    static func subscriptionEndLegend(_ lang: AppLanguage) -> String {
        lang == .zh ? "结束" : "End"
    }
    static func weeklyRefreshLegend(_ lang: AppLanguage) -> String {
        lang == .zh ? "周刷新" : "Weekly reset"
    }
    static func less(_ lang: AppLanguage) -> String { lang == .zh ? "少" : "Less" }
    static func more(_ lang: AppLanguage) -> String { lang == .zh ? "多" : "More" }
    static func today(_ lang: AppLanguage) -> String { lang == .zh ? "今天" : "Today" }

    static func trendVsPrior7d(_ lang: AppLanguage, _ percent: Int) -> String {
        // The trend shares a compact header row with labels such as
        // “30d Tokens”; the shorter English form preserves both pieces at the
        // dashboard's fixed four-column width.
        lang == .zh ? "\(percent)% 较前7天" : "\(percent)% vs 7d"
    }

    static func legendInput(_ lang: AppLanguage) -> String { lang == .zh ? "输入" : "Input" }
    static func legendCached(_ lang: AppLanguage) -> String { lang == .zh ? "缓存" : "Cached" }
    static func legendOutput(_ lang: AppLanguage) -> String { lang == .zh ? "输出" : "Output" }
    static func hoverForBreakdown(_ lang: AppLanguage) -> String {
        lang == .zh ? "悬停查看" : "Hover"
    }
    static func unpricedUsageLabel(_ lang: AppLanguage) -> String {
        lang == .zh ? "未定价" : "Unpriced"
    }

    static func liveOfficialPrice(_ lang: AppLanguage) -> String {
        lang == .zh ? "实时官方价格" : "Live official pricing"
    }
    static func cachedOfflinePrice(_ lang: AppLanguage) -> String {
        lang == .zh ? "离线缓存价格" : "Cached offline pricing"
    }
    static func per1M(_ lang: AppLanguage) -> String { lang == .zh ? "· 每 1M" : "· per 1M" }
    static func noOfficialPriceMapped(_ lang: AppLanguage) -> String {
        lang == .zh ? "暂无费率" : "No rate"
    }
    static func unpriced(_ lang: AppLanguage) -> String { lang == .zh ? "未定价" : "Unpriced" }

    static func noProjectData(_ lang: AppLanguage) -> String {
        lang == .zh ? "暂无项目" : "No projects"
    }
    static func projectModelBreakdownTitle(_ lang: AppLanguage) -> String {
        lang == .zh ? "模型" : "Models"
    }
    static func unattributedProject(_ lang: AppLanguage) -> String {
        lang == .zh ? "未归属" : "Unattributed"
    }
    static func projectModelBreakdownHint(_ lang: AppLanguage) -> String {
        lang == .zh ? "点击查看模型 token 占比" : "Click to view model token shares"
    }
    static func projectExpandDetailHint(_ lang: AppLanguage) -> String {
        lang == .zh ? "点击展开细节" : "Click for details"
    }
    static func projectModelShare(_ lang: AppLanguage, tokens: String, percent: Double) -> String {
        let percentage = String(format: "%.1f", percent)
        return "\(tokens) · \(percentage)%"
    }
    static func projectUsageAccessibilityLabel(_ lang: AppLanguage, project: String, tokens: String) -> String {
        lang == .zh ? "项目 \(project)，\(tokens) token" : "Project \(project), \(tokens) tokens"
    }
    static func modelTokenTrendHint(_ lang: AppLanguage) -> String {
        lang == .zh ? "近 30 天模型 token 趋势" : "Model token trend over the last 30 days"
    }
    static func projectTokenTrendHint(_ lang: AppLanguage) -> String {
        lang == .zh ? "近 90 天项目 token 趋势" : "Project token trend over the last 90 days"
    }
    static func tokenTrendAccessibilityLabel(_ lang: AppLanguage) -> String {
        lang == .zh ? "token 趋势图" : "Token trend chart"
    }

    static func weeklyLabel(_ lang: AppLanguage, isMonthly: Bool) -> String {
        if lang == .zh { return isMonthly ? "每月" : "每周" }
        return isMonthly ? "Monthly" : "Weekly"
    }
    static func dailyLabel(_ lang: AppLanguage) -> String { lang == .zh ? "每天" : "Daily" }
    static func refreshesInDays(_ lang: AppLanguage, days: Int) -> String {
        lang == .zh ? "\(days) 天后刷新" : "Refreshes in \(days)d"
    }
    static func refreshesInHours(_ lang: AppLanguage, hours: Int) -> String {
        lang == .zh ? "\(hours) 小时后刷新" : "Refreshes in \(hours)h"
    }
    static func refreshesInMinutes(_ lang: AppLanguage, minutes: Int) -> String {
        lang == .zh ? "\(minutes) 分钟后刷新" : "Refreshes in \(minutes)m"
    }
    static func remainingDaysHours(_ lang: AppLanguage, days: Int, hours: Int) -> String {
        lang == .zh ? "\(days) 天 \(hours) 小时" : "\(days)d \(hours)h"
    }
    static func remainingHours(_ lang: AppLanguage, hours: Int) -> String {
        lang == .zh ? "\(hours) 小时" : "\(hours)h"
    }
    static func syncing(_ lang: AppLanguage) -> String { lang == .zh ? "同步中…" : "Syncing…" }
    static func planSessions(_ lang: AppLanguage, plan: String, count: Int) -> String {
        lang == .zh ? "\(plan) · \(count) 个会话" : "\(plan) · \(count) sessions"
    }
    static func localSessionsCount(_ lang: AppLanguage, count: Int) -> String {
        lang == .zh ? "\(count) 个会话" : "\(count) sessions"
    }
    static func subscriptionBadge(_ lang: AppLanguage, date: String, daysLeft: Int?) -> String {
        let suffix: String
        if let daysLeft {
            suffix = lang == .zh ? "（还剩 \(daysLeft) 天）" : " (\(daysLeft)d left)"
        } else {
            suffix = ""
        }
        return (lang == .zh ? "会员到期 \(date)" : "Renews \(date)") + suffix
    }
    static func subscriptionHelp(_ lang: AppLanguage) -> String {
        lang == .zh
            ? "来自本地 Codex 登录凭据（auth.json）中的 ChatGPT 订阅信息，与账号页一致"
            : "From the ChatGPT subscription info in the local Codex login credentials (auth.json), matching the account page"
    }

    static func sessionTitle(_ lang: AppLanguage) -> String { lang == .zh ? "会话" : "Session" }
    static func usageOverviewTitle(_ lang: AppLanguage) -> String { lang == .zh ? "用量" : "Usage" }
    static func modelBreakdownTitle(_ lang: AppLanguage) -> String {
        lang == .zh ? "模型" : "Models"
    }
    static func topProjectsTitle(_ lang: AppLanguage) -> String {
        lang == .zh ? "项目" : "Projects"
    }
    static func activityTitle(_ lang: AppLanguage, title: String) -> String {
        lang == .zh ? "正在处理 · \(title)" : "Working · \(title)"
    }
    static func activityAge(
        _ lang: AppLanguage,
        seconds: Int,
        scope: ProjectActivity.TimingScope = .currentTurn
    ) -> String {
        let prefix: String
        switch (lang, scope) {
        case (.zh, .currentTurn): prefix = "本轮 "
        case (.zh, .continuousGoal): prefix = "Goal 累计 "
        case (.en, .currentTurn): prefix = "turn "
        case (.en, .continuousGoal): prefix = "Goal total "
        }
        guard seconds >= 60 else { return "\(prefix)\(max(0, seconds))s" }
        let (hours, minutes) = Formatting.hoursAndMinutes(fromSeconds: seconds)
        let duration = hours > 0 ? "\(hours)h\(minutes)m" : "\(minutes)m"
        return prefix + duration
    }
    static func activityPhase(_ lang: AppLanguage, phase: ProjectActivity.Phase) -> String {
        switch phase {
        case .working: return lang == .zh ? "处理中" : "Working"
        case .thinking: return lang == .zh ? "正在分析" : "Analyzing"
        case .usingTool: return lang == .zh ? "正在执行工具" : "Using tools"
        case .usingScreen: return lang == .zh ? "正在操作屏幕" : "Controlling screen"
        case .editing: return lang == .zh ? "正在修改文件" : "Editing files"
        }
    }
    static func activityTokens(_ lang: AppLanguage, tokens: String) -> String {
        lang == .zh ? "会话 \(tokens)" : "Session \(tokens)"
    }
    static func activityContextHint(_ lang: AppLanguage) -> String {
        lang == .zh ? "当前上下文 / 对话累计" : "Current context / conversation total"
    }
    static func activityContextAccessibility(
        _ lang: AppLanguage,
        current: String,
        total: String
    ) -> String {
        lang == .zh
            ? "当前上下文 \(current)，对话累计 \(total)"
            : "Current context \(current), conversation total \(total)"
    }
    static func activityAccessibilityLabel(
        _ lang: AppLanguage,
        title: String,
        project: String,
        phase: ProjectActivity.Phase
    ) -> String {
        lang == .zh
            ? "对话 \(title)，项目 \(project)，\(activityPhase(lang, phase: phase))"
            : "Conversation \(title), project \(project), \(activityPhase(lang, phase: phase))"
    }
    static func activityOutcomeLabel(_ lang: AppLanguage, outcome: ActivityOutcome) -> String {
        switch outcome {
        case .completed: return lang == .zh ? "已完成" : "Done"
        case .aborted: return lang == .zh ? "已中断" : "Stopped"
        case .timedOut: return lang == .zh ? "已暂停" : "Paused"
        }
    }
    static func activityCompletedAccessibilityLabel(_ lang: AppLanguage, project: String, outcome: ActivityOutcome) -> String {
        lang == .zh
            ? "项目 \(project)，\(activityOutcomeLabel(lang, outcome: outcome))"
            : "Project \(project), \(activityOutcomeLabel(lang, outcome: outcome))"
    }
    static func activityCompletionSummary(_ lang: AppLanguage) -> String {
        lang == .zh ? "任务已完成" : "Tasks completed"
    }
    static func activityCompletionSummaryAction(_ lang: AppLanguage) -> String {
        lang == .zh ? "点击查看" : "View"
    }
    static func activityCompletionSummaryAccessibilityLabel(_ lang: AppLanguage, count: Int) -> String {
        lang == .zh
            ? "\(count) 个任务已完成，点击查看"
            : "\(count) tasks completed, click to view"
    }
    static func updateCapsuleLabel(_ lang: AppLanguage, version: String, downloaded: Bool) -> String {
        if lang == .zh { return downloaded ? "v\(version) 已拉取" : "可更新 v\(version)" }
        return downloaded ? "v\(version) downloaded" : "Update v\(version)"
    }
    static func updateAccessibilityLabel(_ lang: AppLanguage, version: String, downloaded: Bool) -> String {
        if lang == .zh {
            return downloaded
                ? "aibar v\(version) 更新包已下载，点击在访达中显示"
                : "aibar v\(version) 可更新，点击查看发布页面"
        }
        return downloaded
            ? "aibar version \(version) downloaded, click to reveal in Finder"
            : "aibar version \(version) available, click to view the release"
    }
    static func checkForUpdates(_ lang: AppLanguage) -> String {
        lang == .zh ? "检查更新" : "Check for Updates"
    }

    static func hourWindow(_ lang: AppLanguage, _ hours: Int) -> String {
        lang == .zh ? "\(hours)h 窗口" : "\(hours)h window"
    }
    static func dayWindow(_ lang: AppLanguage, _ days: Int) -> String {
        lang == .zh ? "\(days)d 窗口" : "\(days)d window"
    }
    static func peakNd(_ lang: AppLanguage, days: Int, money: String) -> String {
        lang == .zh ? "近 \(days) 天峰值 \(money)" : "\(days)d peak \(money)"
    }
    static func averageDailyTokens30d(_ lang: AppLanguage, tokens: String) -> String {
        lang == .zh ? "30 天日均 \(tokens)" : "30d avg \(tokens)"
    }
    static func pricingSynced(_ lang: AppLanguage) -> String { lang == .zh ? "实时费率" : "Live rates" }
    static func pricingPartial(_ lang: AppLanguage) -> String {
        lang == .zh ? "混合费率" : "Mixed rates"
    }
    static func pricingOffline(_ lang: AppLanguage) -> String {
        lang == .zh ? "缓存费率" : "Cached rates"
    }
    static func mcpCallsAndEdits(_ lang: AppLanguage, calls: Int, edits: Int) -> String {
        lang == .zh ? "\(calls) 次 MCP 调用 · \(edits) 次修改" : "\(calls) MCP calls · \(edits) file edits"
    }
    static func mcpActivityTitle(_ lang: AppLanguage) -> String {
        "MCP"
    }
    static func mcpCallsTitle(_ lang: AppLanguage) -> String {
        lang == .zh ? "MCP 调用" : "MCP Calls"
    }
    static func filesChangedTitle(_ lang: AppLanguage) -> String {
        lang == .zh ? "修改" : "Edits"
    }
    static func last30Days(_ lang: AppLanguage) -> String {
        lang == .zh ? "30 天" : "30d"
    }
    static func noMCPActivity(_ lang: AppLanguage) -> String {
        lang == .zh ? "暂无 MCP 调用记录" : "No MCP activity captured yet"
    }
    static func toolHeatmapHint(_ lang: AppLanguage) -> String {
        lang == .zh ? "方格亮度表示调用次数" : "Square brightness shows call volume"
    }
    static func toolHeatmapLow(_ lang: AppLanguage) -> String {
        lang == .zh ? "少" : "Low"
    }
    static func toolHeatmapHigh(_ lang: AppLanguage) -> String {
        lang == .zh ? "多" : "High"
    }
    static func activityFlowTitle(_ lang: AppLanguage) -> String {
        lang == .zh ? "流程" : "Flow"
    }
    static func activityFlowSession(_ lang: AppLanguage) -> String {
        lang == .zh ? "会话" : "Session"
    }
    static func activityFlowTool(_ lang: AppLanguage) -> String {
        lang == .zh ? "工具" : "Tool"
    }
    static func activityFlowFiles(_ lang: AppLanguage) -> String {
        lang == .zh ? "文件" : "Files"
    }

    static func todayCost(_ lang: AppLanguage) -> String {
        lang == .zh ? "今日费用" : "Today"
    }
    static func monthCost(_ lang: AppLanguage) -> String {
        lang == .zh ? "30 天费用" : "30d Cost"
    }
    static func monthTokens(_ lang: AppLanguage) -> String { lang == .zh ? "30 天 Token" : "30d Tokens" }
    static func latestSessionTokens(_ lang: AppLanguage) -> String {
        lang == .zh ? "最近会话" : "Last Session"
    }

    static func footnotePriced(_ lang: AppLanguage) -> String {
        lang == .zh
            ? "账号每日 token 为官方值；模型、项目及输入/cache/输出占比来自本地会话，并按公开 API 费率估算；不是订阅账单。"
            : "Official daily account tokens; model, project, and input/cache/output shares come from local sessions and use public API rates. Not a bill."
    }
    static func footnoteUnpriced(_ lang: AppLanguage, models: String) -> String {
        lang == .zh
            ? "账号每日 token 为官方值，本地会话用于模型/项目归属；\(models) 未定价，仅统计 token；不是订阅账单。"
            : "Official daily account tokens with local model/project attribution; \(models) unpriced and token-only. Not a bill."
    }

    static func refreshNow(_ lang: AppLanguage) -> String { lang == .zh ? "立即刷新" : "Refresh Now" }
    static func quitApp(_ lang: AppLanguage) -> String { lang == .zh ? "退出用量监控" : "Quit Usage Monitor" }
    static func showPanel(_ lang: AppLanguage) -> String { lang == .zh ? "显示面板" : "Show Panel" }
    static func hidePanel(_ lang: AppLanguage) -> String { lang == .zh ? "隐藏面板" : "Hide Panel" }
    static func activityCapsuleMenuTitle(_ lang: AppLanguage) -> String { lang == .zh ? "显示活动胶囊" : "Show Activity Capsule" }
    static func screenshotMenuTitle(_ lang: AppLanguage) -> String { lang == .zh ? "截图并标注（fn + 4）" : "Capture & Mark Up (fn + 4)" }

    static func shareTooltip(_ lang: AppLanguage) -> String { lang == .zh ? "分享用量报告" : "Share usage report" }
    static func shareTitle(_ lang: AppLanguage, provider: String) -> String {
        lang == .zh ? "\(provider) 用量报告" : "\(provider) Usage Report"
    }
    static func sharePreviewCaption(_ lang: AppLanguage) -> String {
        lang == .zh ? "生成的分享卡片" : "Generated share card"
    }
    static func shareToX(_ lang: AppLanguage) -> String { lang == .zh ? "分享到 X" : "Share to X" }
    static func shareCopyImage(_ lang: AppLanguage) -> String { lang == .zh ? "复制图片" : "Copy Image" }
    static func shareSaveImage(_ lang: AppLanguage) -> String { lang == .zh ? "保存图片…" : "Save Image…" }
    static func shareMorePlatforms(_ lang: AppLanguage) -> String {
        lang == .zh ? "更多分享方式…" : "More Sharing Options…"
    }
    static func shareImageCopiedHint(_ lang: AppLanguage) -> String {
        lang == .zh ? "图片已复制，粘贴到推文中即可" : "Image copied — paste it into your post"
    }
    static func shareImageSavedHint(_ lang: AppLanguage) -> String { lang == .zh ? "图片已保存" : "Image saved" }
    static func shareStyleLabel(_ lang: AppLanguage) -> String { lang == .zh ? "卡片风格" : "Card style" }
    static func shareSessionsLabel(_ lang: AppLanguage) -> String { lang == .zh ? "本地会话" : "Sessions" }
    static func shareToXAlertTitle(_ lang: AppLanguage) -> String {
        lang == .zh ? "图片已复制到剪贴板" : "Image copied to clipboard"
    }
    static func shareToXAlertMessage(_ lang: AppLanguage) -> String {
        lang == .zh
            ? "X 网页不支持直接带图打开发文框，接下来会打开 X 并填好文字，请在发文框里按 ⌘V 粘贴图片。"
            : "X's web compose box can't accept an image via link, so text and image travel separately: X will open next with the text pre-filled — press ⌘V inside the compose box to paste the image."
    }
    static func shareToXAlertOpen(_ lang: AppLanguage) -> String { lang == .zh ? "打开 X" : "Open X" }
    static func shareToXAlertCancel(_ lang: AppLanguage) -> String { lang == .zh ? "取消" : "Cancel" }

    static func noLocalRecord(_ lang: AppLanguage) -> String { lang == .zh ? "暂无本地记录" : "No local record yet" }
    static func waitingForSync(_ lang: AppLanguage) -> String { lang == .zh ? "等待最新同步" : "Waiting for sync" }
    static func resetsInDaysHours(_ lang: AppLanguage, days: Int, hours: Int) -> String {
        lang == .zh ? "\(days)d \(hours)h 后重置" : "resets in \(days)d \(hours)h"
    }
    static func resetsInHoursMinutes(_ lang: AppLanguage, hours: Int, minutes: Int) -> String {
        lang == .zh ? "\(hours)h \(minutes)m 后重置" : "resets in \(hours)h \(minutes)m"
    }
    static func resetsInMinutes(_ lang: AppLanguage, minutes: Int) -> String {
        lang == .zh ? "\(minutes)m 后重置" : "resets in \(minutes)m"
    }
    static func updatedAt(_ lang: AppLanguage, time: String) -> String {
        lang == .zh ? "\(time) 已更新" : "Updated \(time)"
    }
    static func resetCount(_ lang: AppLanguage, _ count: Int) -> String {
        lang == .zh ? "本机已重置 \(count) 次" : "\(count) resets seen"
    }

    static func traeCNNoData(_ lang: AppLanguage) -> String {
        lang == .zh
            ? "Trae CN 暂无可读取的本地用量记录：其任务/对话历史似乎只保存在云端，本地未发现可靠的 token 用量日志，因此这里不展示编造的数据。"
            : "No readable local usage records for Trae CN: its task/chat history appears to live server-side only, and no reliable local token usage log was found, so no fabricated numbers are shown here."
    }
}
