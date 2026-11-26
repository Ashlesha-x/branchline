import SwiftUI

/// A step-by-step tour of the main window: each stop highlights one control with a bubble
/// that has 跳过, 上一步 and 下一步. New users get the full tour the first time the demo space
/// opens (replayable from 设置 › 通用); after an update, returning users only see the stops
/// introduced since the version they last saw.
enum TourStop: Int, CaseIterable, Hashable {
    case projects, record, views, agenda, review, spaces, settings
    var title: String {
        switch self {
        case .projects: "项目和分支"
        case .record: "记一笔"
        case .views: "三种看法"
        case .agenda: "待办"
        case .review: "回顾"
        case .spaces: "工作区"
        case .settings: "设置"
        }
    }
    /// The version that added the feature; an update shows the stops newer than the last seen version.
    var introduced: String {
        switch self {
        case .spaces, .settings: "0.17.1"
        default: "0.1.0"
        }
    }
    func text(demo: Bool) -> String {
        switch self {
        case .projects: "左边是你的项目，以及从项目里拉出来的分支。点一个项目就只看它；项目右侧的菜单可以新建记录、拉出新分支。"
        case .record: "「记进度」随手写下一步进展。「新增」里还能建任务 / DDL、会议、项目和分支。⌘N 也可以新建记录。"
        case .views: "时间轴按日期排开所有记录；脉络图看分支怎么拉出来、成果怎么合并回去；列表方便逐条翻看。"
        case .agenda: "今天要做的、已经逾期的、未来七天的任务和会议都在这里，勾掉就算完成。"
        case .review: "选一段时间，脉络会把这段时间的进展整理成一份回顾，可以改写，也能导出 Markdown。"
        case .spaces: "在这里切换工作区，或者新建一个，把不同的事分开放。重命名也在这里；删除在 设置 › 通用 › 工作区。" + (demo ? "现在这个示例空间只是体验用，改动不会保存。" : "")
        case .settings: "设置回到了主窗口，左边按分区排列：提醒、日历同步、iCloud 备份和 AI 接入都在里面。不想再看到示例空间，可以在 设置 › 通用 关掉「显示示例空间」。"
        }
    }
}

struct TourAnchorKey: PreferenceKey {
    static let defaultValue: [TourStop: Anchor<CGRect>] = [:]
    static func reduce(value: inout [TourStop: Anchor<CGRect>], nextValue: () -> [TourStop: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    func tourAnchor(_ stop: TourStop) -> some View {
        anchorPreference(key: TourAnchorKey.self, value: .bounds) { [stop: $0] }
    }
}

extension AppStore {
    static let tourSeenKey = "tour.seen"
    static let tourVersionKey = "tour.seenVersion"
    static var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
    /// The full tour.
    func startTour() { startTour(TourStop.allCases, update: false) }
    func startTour(_ stops: [TourStop], update: Bool) {
        guard let first = stops.first else { return }
        UserDefaults.standard.set(false, forKey: "canvasSidebarHidden")
        editor = nil
        tourStops = stops; tourIsUpdate = update
        showTourStop(first)
    }
    /// Called once at launch: new users only get the version recorded; returning users see the new stops.
    func planUpdateTour(returningUser: Bool) {
        let defaults = UserDefaults.standard
        let seen = defaults.string(forKey: Self.tourVersionKey)
        // Returning users already know the app: the demo space no longer starts the full tour for them.
        if returningUser { defaults.set(true, forKey: Self.tourSeenKey) }
        let stops = OnboardingPlan.stopsToShow(TourStop.allCases.map { (stop: $0, introduced: $0.introduced) }, seen: seen, returningUser: returningUser, current: Self.appVersion)
        if stops.isEmpty || isDemo { defaults.set(Self.appVersion, forKey: Self.tourVersionKey); return }
        startTour(stops, update: true)
    }
    func showTourStop(_ stop: TourStop) {
        switch stop {
        case .projects, .record, .views, .spaces:
            if mainPage != .projects || projectFilter != nil || selection != nil || !search.isEmpty {
                browse { mainPage = .projects; projectFilter = nil; selection = nil; search = "" }
            }
            searchPanelVisible = false
            if stop == .views && mode == .list { mode = .timeline }
        case .agenda: browse { mainPage = .agenda; projectFilter = nil; selection = nil; search = "" }
        case .review: openReview()
        case .settings: openSettings(.general)
        }
        tourStop = stop
    }
    func advanceTour(by step: Int) {
        guard let current = tourStop, let index = tourStops.firstIndex(of: current) else { return }
        let next = index + step
        guard tourStops.indices.contains(next) else { endTour(); return }
        showTourStop(tourStops[next])
    }
    /// Skipping or finishing both count as seen; the last stop leaves the settings page open.
    func endTour() {
        let finished = tourStop == .settings
        tourStop = nil
        if !tourIsUpdate { UserDefaults.standard.set(true, forKey: Self.tourSeenKey) }
        UserDefaults.standard.set(Self.appVersion, forKey: Self.tourVersionKey)
        if !finished { browse { mainPage = .projects; selection = nil } }
    }
}

struct TourOverlay: View {
    @Bindable var store: AppStore
    let anchors: [TourStop: Anchor<CGRect>]
    private let bubbleWidth: CGFloat = 300
    private let bubbleHeight: CGFloat = 190
    var body: some View {
        GeometryReader { proxy in
            if let stop = store.tourStop {
                let target = anchors[stop].map { proxy[$0].insetBy(dx: -6, dy: -4) }
                ZStack(alignment: .topLeading) {
                    Path { path in
                        path.addRect(CGRect(origin: .zero, size: proxy.size))
                        if let target { path.addRoundedRect(in: target, cornerSize: CGSize(width: 8, height: 8)) }
                    }
                    .fill(Color.black.opacity(0.32), style: FillStyle(eoFill: true))
                    .contentShape(Rectangle())
                    .onTapGesture {}
                    if let target {
                        RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 2)
                            .frame(width: target.width, height: target.height)
                            .offset(x: target.minX, y: target.minY)
                            .allowsHitTesting(false)
                    }
                    bubble(stop)
                        .frame(width: bubbleWidth)
                        .position(position(for: target, in: proxy.size))
                }
                .animation(.easeInOut(duration: 0.2), value: stop)
            }
        }
    }
    private func bubble(_ stop: TourStop) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            let index = store.tourStops.firstIndex(of: stop) ?? 0
            Text((store.tourIsUpdate ? "本次更新 · " : "") + "\(index + 1) / \(store.tourStops.count)").font(.caption).foregroundStyle(.secondary)
            Text(stop.title).font(.headline)
            Text(stop.text(demo: store.isDemo)).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("跳过") { store.endTour() }.buttonStyle(.link).keyboardShortcut(.cancelAction)
                Spacer()
                if index > 0 { Button("上一步") { store.advanceTour(by: -1) } }
                Button(stop == store.tourStops.last ? "完成" : "下一步") { store.advanceTour(by: 1) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }.padding(.top, 4)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
    }
    /// Beside the target when there is room on the right, otherwise below or above it; centered without a target.
    private func position(for target: CGRect?, in size: CGSize) -> CGPoint {
        let halfW = bubbleWidth / 2, halfH = bubbleHeight / 2, gap: CGFloat = 14
        func clampX(_ x: CGFloat) -> CGFloat { min(max(x, halfW + 12), size.width - halfW - 12) }
        func clampY(_ y: CGFloat) -> CGFloat { min(max(y, halfH + 12), size.height - halfH - 12) }
        guard let target else { return CGPoint(x: size.width / 2, y: size.height / 2) }
        if target.maxX + gap + bubbleWidth + 12 <= size.width && target.width < size.width / 3 {
            return CGPoint(x: target.maxX + gap + halfW, y: clampY(target.midY))
        }
        if target.maxY + gap + bubbleHeight + 12 <= size.height {
            return CGPoint(x: clampX(target.midX), y: target.maxY + gap + halfH)
        }
        return CGPoint(x: clampX(target.midX), y: clampY(target.minY - gap - halfH))
    }
}
