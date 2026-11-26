import SwiftUI

/// A step-by-step tour of the main window: each stop highlights one control with a bubble
/// that has 跳过, 上一步 and 下一步. It starts the first time the demo space opens and can be
/// replayed from 设置 › 通用.
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
    var text: String {
        switch self {
        case .projects: "左边是你的项目，以及从项目里拉出来的分支。点一个项目就只看它；项目右侧的菜单可以新建记录、拉出新分支。"
        case .record: "「记进度」随手写下一步进展。「新增」里还能建任务 / DDL、会议、项目和分支。⌘N 也可以新建记录。"
        case .views: "时间轴按日期排开所有记录；脉络图看分支怎么拉出来、成果怎么合并回去；列表方便逐条翻看。"
        case .agenda: "今天要做的、已经逾期的、未来七天的任务和会议都在这里，勾掉就算完成。"
        case .review: "选一段时间，脉络会把这段时间的进展整理成一份回顾，可以改写，也能导出 Markdown。"
        case .spaces: "在这里切换工作区，或者新建一个，把不同的事分开放。现在这个示例空间只是体验用，改动不会保存。"
        case .settings: "提醒、日历同步、iCloud 备份和 AI 接入都在设置里。不想再看到示例空间，可以在 设置 › 通用 关掉「显示示例空间」。"
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
    func startTour() {
        UserDefaults.standard.set(false, forKey: "canvasSidebarHidden")
        editor = nil
        showTourStop(.projects)
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
        guard let current = tourStop else { return }
        guard let next = TourStop(rawValue: current.rawValue + step) else { endTour(); return }
        showTourStop(next)
    }
    /// Skipping or finishing both count as seen; the last stop leaves the settings page open.
    func endTour() {
        let finished = tourStop == .settings
        tourStop = nil
        UserDefaults.standard.set(true, forKey: Self.tourSeenKey)
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
            Text("\(stop.rawValue + 1) / \(TourStop.allCases.count)").font(.caption).foregroundStyle(.secondary)
            Text(stop.title).font(.headline)
            Text(stop.text).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("跳过") { store.endTour() }.buttonStyle(.link).keyboardShortcut(.cancelAction)
                Spacer()
                if stop.rawValue > 0 { Button("上一步") { store.advanceTour(by: -1) } }
                Button(stop == TourStop.allCases.last ? "完成" : "下一步") { store.advanceTour(by: 1) }
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
