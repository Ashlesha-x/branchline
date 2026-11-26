import SwiftUI
import ProgressCore

private struct RoadmapLane: Identifiable {
    var id: UUID
    var title: String
    var color: Int
    var start: Date
    var end: Date?
    var status: WorkStatus
    var isProject: Bool
}

struct RoadmapView: View {
    @Bindable var store: AppStore
    @LocalState private var ready = false
    @LocalState private var scrollY: CGFloat = 0
    @LocalState private var scrollX: CGFloat = 0
    @LocalState private var verticalPosition = ScrollPosition(y: 0)
    @LocalState private var horizontalPosition = ScrollPosition(x: 0)
    private let top: CGFloat = 22
    private let spacing: CGFloat = 25

    private var summaries: Set<UUID> {
        Set((store.visibleProjects.map(\.id) + store.workspace.branches.map(\.id)).filter { store.routeIsSummary($0, in: .graph) || store.isCollapsed($0, in: .graph) })
    }
    private var rows: [RoadmapRow] {
        store.workspace.presentedRoadmap(projectIDs: store.visibleProjects.map(\.id), collapsed: store.collapsedIDs(in: .graph), records: store.filteredRecords, includeIndependent: store.projectFilter == nil, summary: summaries, layout: store.routeLayout(in: .graph), groupDistantTasks: true, expandedTaskFamilies: store.expandedFutureTaskSeries, revealedRecordID: store.selectedEntityID)
    }
    private var lanes: [RoadmapLane] {
        let visibleIDs = Set(rows.map(\.laneID))
        return store.routeLayout(in: .graph).compactMap { item in
            guard visibleIDs.contains(item.id) else { return nil }
            if let project = store.workspace.project(item.id) { return RoadmapLane(id: project.id, title: project.title, color: project.color, start: project.createdAt, end: project.closedAt ?? project.archivedAt, status: project.status, isProject: true) }
            guard let branch = store.workspace.branch(item.id) else { return nil }
            return RoadmapLane(id: branch.id, title: branch.title, color: branch.color, start: branch.startAt, end: branch.closedAt ?? branch.archivedAt, status: branch.status, isProject: false)
        }
    }
    private func rowHeight(_ row: RoadmapRow) -> CGFloat {
        if row.events.first?.kind == .statusGroup { return 36 }
        let summary = summaries.contains(row.laneID) && row.events.first?.kind == .start
        return (store.expandedGraphRows.contains(row.id) ? 48 + CGFloat(row.events.count) * 66 : 46) + (summary ? 24 : 0)
    }
    private func positions(_ rows: [RoadmapRow]) -> [CGFloat] {
        var next = top
        return rows.map { row in let y = next + 22; next += rowHeight(row); return y }
    }
    var body: some View {
        GeometryReader { geometry in
            let events = rows, tracks = lanes, centers = positions(events)
            let focus = store.focusedRouteIDs
            let graphWidth = max(112, CGFloat(tracks.count) * spacing + 34)
            let contentWidth = max(geometry.size.width - 16, graphWidth + 410)
            let height = top + events.reduce(CGFloat(0)) { $0 + rowHeight($1) } + 18
            let viewportHeight = max(100, geometry.size.height - 17)
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    ScrollView(.vertical) {
                        ScrollView(.horizontal) {
                            ZStack(alignment: .topLeading) {
                                paths(rows: events, lanes: tracks, centers: centers, width: contentWidth, height: height)
                                ForEach(Array(events.enumerated()), id: \.element.id) { index, row in
                                    if row.events.first?.kind == .statusGroup, let status = RouteGroups.statuses.first(where: { RouteGroups.id($0) == row.laneID }) {
                                        RouteStatusButton(store: store, status: status, scope: .graph)
                                            .frame(width: contentWidth, height: 36).background(Color(nsColor: .controlBackgroundColor))
                                            .position(x: contentWidth / 2, y: centers[index] - 4).zIndex(4)
                                    } else if let laneIndex = tracks.firstIndex(where: { $0.id == row.laneID }) {
                                        let lane = tracks[laneIndex]
                                        let folded = lane.isProject && store.isCollapsed(lane.id, in: .graph)
                                        let color = projectColor(lane.color)
                                        let event = row.events[0]
                                        let symbol = event.kind == .deadline ? "flag.fill" : event.kind == .merge ? "diamond.fill" : event.kind == .taskSeries ? "repeat" : nil
                                        RoadmapDot(color: color.opacity(focus.isEmpty || focus.contains(lane.id) ? 1 : 0.45), count: row.events.count, symbol: symbol, expanded: store.expandedGraphRows.contains(row.id), label: "\(folded ? "展开项目" : "展开节点")：\(lane.title) · \(event.title)") {
                                            if let family = row.events[0].taskFamilyID { store.expandedFutureTaskSeries.insert(family) }
                                            else if folded { store.toggleCollapsed(lane.id, in: .graph) }
                                            else if summaries.contains(lane.id) && row.events.first?.kind == .start { store.toggleRouteDetails(lane.id, in: .graph) }
                                            else if store.expandedGraphRows.contains(row.id) { store.expandedGraphRows.remove(row.id) }
                                            else { store.expandedGraphRows.insert(row.id) }
                                        }.opacity(!store.isSearching || row.events.contains(where: { store.matchingIDs.contains($0.entityID) }) ? 1 : 0.3).position(x: 24 + CGFloat(laneIndex) * spacing, y: centers[index]).zIndex(2)
                                        rowContent(row, lane: lane, folded: folded)
                                            .frame(width: contentWidth - graphWidth - 16, height: rowHeight(row), alignment: .topLeading)
                                            .offset(x: graphWidth, y: centers[index] - 22)
                                            .opacity(!store.isSearching || row.events.contains(where: { store.matchingIDs.contains($0.entityID) }) ? 1 : 0.3)
                                    }
                                }
                            }.frame(width: contentWidth, height: height).background(NativeScrollIndicatorHider())
                        }.scrollIndicators(.hidden).scrollPosition($horizontalPosition)
                            .onScrollGeometryChange(for: CGFloat.self) { max(0, $0.contentOffset.x) } action: { _, value in scrollX = value; if ready { store.trackViewport("graph", x: value) } }
                            .frame(height: height)
                    }.scrollIndicators(.hidden).scrollPosition($verticalPosition)
                        .onScrollGeometryChange(for: CGFloat.self) { max(0, $0.contentOffset.y) } action: { _, value in scrollY = value; if ready { store.trackViewport("graph", y: value) } }
                    PersistentScroller(offset: scrollY, contentLength: height, viewportLength: viewportHeight) { verticalPosition.scrollTo(y: $0) }.frame(width: 16)
                }
                PersistentScroller(horizontal: true, offset: scrollX, contentLength: contentWidth, viewportLength: geometry.size.width - 16) { horizontalPosition.scrollTo(x: $0) }.frame(height: 16)
            }.background(Color(nsColor: .textBackgroundColor))
                .task(id: store.browseRestoreToken) {
                    let savedOffset = store.viewportToRestore("graph")
                    let offset = savedOffset ?? BrowseOffset()
                    await Task.yield(); guard !Task.isCancelled else { return }
                    if (store.revealBrowseSelection || savedOffset == nil), let id = store.selectedEntityID, let index = rows.firstIndex(where: { $0.events.contains { $0.entityID == id } }) {
                        store.expandedGraphRows.insert(rows[index].id)
                        await Task.yield(); guard !Task.isCancelled else { return }
                        if let current = rows.firstIndex(where: { $0.events.contains { $0.entityID == id } }) {
                            verticalPosition.scrollTo(y: max(0, positions(rows)[current] - viewportHeight * 0.35))
                        }
                    } else if savedOffset == nil {
                        let active = rows.indices.prefix { rows[$0].events.first?.kind != .statusGroup }
                        let today = Calendar.current.startOfDay(for: Date())
                        if let current = active.min(by: { abs(rows[$0].date.timeIntervalSince(today)) < abs(rows[$1].date.timeIntervalSince(today)) }) {
                            verticalPosition.scrollTo(y: max(0, centers[current] - viewportHeight * 0.25))
                        }
                    } else { horizontalPosition.scrollTo(x: offset.x); verticalPosition.scrollTo(y: offset.y) }
                    ready = true
                }
        }
    }
    private func rowContent(_ row: RoadmapRow, lane: RoadmapLane, folded: Bool) -> some View {
        let event = row.events[0]
        let today = Calendar.current.isDateInToday(row.date)
        let date = event.through.map { shortDate(row.date) + "–" + shortDate($0) } ?? (today ? "今天" : shortDate(row.date))
        let title = folded ? lane.status.title : event.kind == .taskSeries ? "\(event.title) · 后续 \(event.taskCount ?? 1) 次" : row.events.count > 1 ? "\(row.events.count) 条记录" : event.title
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                if let family = row.events[0].taskFamilyID { store.expandedFutureTaskSeries.insert(family) }
                else if folded { store.toggleCollapsed(lane.id, in: .graph) }
                else if store.expandedGraphRows.contains(row.id) { store.expandedGraphRows.remove(row.id) }
                else { store.expandedGraphRows.insert(row.id) }
            } label: {
                HStack(spacing: 10) {
                    HStack(spacing: 6) {
                        Image(systemName: lane.isProject ? "folder.fill" : store.branchSymbol(lane.id)).foregroundStyle(projectColor(lane.color))
                        Text(lane.title).foregroundStyle(store.selectedRouteID == lane.id ? Color.primary : Color.secondary)
                    }.font(.caption.weight(.medium)).lineLimit(1).frame(width: 132, alignment: .leading).help(lane.title)
                    Text(title).lineLimit(1).help(event.kind == .taskSeries ? "\(event.title) · \((store.workspace.record(event.entityID)?.taskRepeatRule ?? .none).title)" : title)
                    Spacer(minLength: 4)
                    Text(date).font(.caption.monospacedDigit().weight(today ? .semibold : .regular))
                        .foregroundStyle(today ? Color.accentColor : Color.secondary)
                    Image(systemName: store.expandedGraphRows.contains(row.id) ? "chevron.down" : "chevron.right").font(.caption2).foregroundStyle(.secondary)
                }.frame(height: 44).contentShape(Rectangle())
            }.buttonStyle(.plain)
            if summaries.contains(lane.id), row.events.first?.kind == .start {
                HStack {
                    RouteSummaryText(store: store, routeID: lane.id, now: Date())
                    Spacer(minLength: 3)
                    Button("展开记录") { if folded { store.toggleCollapsed(lane.id, in: .graph) }; store.toggleRouteDetails(lane.id, in: .graph) }.buttonStyle(.plain).font(.caption2).foregroundStyle(.tint).accessibilityLabel("展开记录：\(lane.title)")
                }.frame(height: 24)
            }
            if store.expandedGraphRows.contains(row.id) {
                ForEach(row.events) { event in
                    Button { show(event, lane: lane) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack { Text(event.title).fontWeight(.medium).lineLimit(1); Spacer(); Image(systemName: "arrow.up.right").font(.caption) }
                            Text(detail(event)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }.padding(.horizontal, 12).frame(height: 60, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
                            .background(projectColor(lane.color).opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
                    }.buttonStyle(.plain).padding(.bottom, 6).accessibilityLabel("查看详情：\(event.title)")
                }
            }
        }
    }
    private func detail(_ event: RoadmapEvent) -> String {
        let date = fullDate(event.date)
        if let record = store.workspace.record(event.entityID) { return date + " · " + (record.body.isEmpty ? record.kind.title : record.body) + (record.repeatRule == .none ? "" : " · \(record.repeatRule.title)重复") }
        if event.kind == .merge { return date + " · 阶段成果合并，点击查看摘要与来源记录" }
        return date + " · 点击查看工作线索"
    }
    private func show(_ event: RoadmapEvent, lane: RoadmapLane) {
        store.browse {
            if event.kind == .merge { store.selection = .merge(event.entityID) }
            else if store.workspace.record(event.entityID) != nil { store.selection = .record(event.entityID) }
            else { store.selection = lane.isProject ? .project(lane.id) : .branch(lane.id) }
        }
    }

    private func paths(rows: [RoadmapRow], lanes: [RoadmapLane], centers: [CGFloat], width: CGFloat, height: CGFloat) -> some View {
        Canvas { context, _ in
            if store.isSearching { context.opacity = 0.3 }
            func x(_ id: UUID) -> CGFloat? { lanes.firstIndex { $0.id == id }.map { 24 + CGFloat($0) * spacing } }
            let layout = store.routeLayout(in: .graph)
            let workspace = store.workspace
            func status(_ id: UUID) -> WorkStatus {
                layout.first { $0.id == id }?.ownerProjectID.flatMap { workspace.project($0)?.status } ?? .active
            }
            func y(_ date: Date, lane: UUID) -> CGFloat {
                let indices = rows.indices.filter { rows[$0].events.first?.kind != .statusGroup && status(rows[$0].laneID) == status(lane) }
                guard let first = indices.first, let last = indices.last else { return top }
                if date >= rows[first].date { return centers[first] }
                if date <= rows[last].date { return centers[last] }
                guard let n = indices.firstIndex(where: { rows[$0].date <= date }), n > 0 else { return centers[first] }
                let before = indices[n - 1], after = indices[n]
                let duration = rows[before].date.timeIntervalSince(rows[after].date)
                let fraction = rows[before].date.timeIntervalSince(date) / max(1, duration)
                return centers[before] + CGFloat(fraction) * (centers[after] - centers[before])
            }
            for (index, row) in rows.enumerated() {
                if index % 2 == 0 {
                    context.fill(Path(CGRect(x: 0, y: centers[index] - 22, width: width, height: rowHeight(row))), with: .color(.primary.opacity(0.025)))
                }
            }
            for lane in lanes {
                guard let lx = x(lane.id), let startIndex = rows.firstIndex(where: { $0.events.contains { $0.kind == .start && $0.laneID == lane.id } }) else { continue }
                let startY = centers[startIndex]
                let related = rows.indices.filter { rows[$0].laneID == lane.id || rows[$0].events.contains { $0.sourceLaneID == lane.id } }
                let latestY = related.map { centers[$0] }.min() ?? startY
                let endY = lane.end.map { y($0, lane: lane.id) } ?? min(latestY, y(Date(), lane: lane.id))
                let solidEnd = max(endY, y(Date(), lane: lane.id))
                let color = projectColor(lane.color)
                var line = Path(); line.move(to: CGPoint(x: lx, y: startY)); line.addLine(to: CGPoint(x: lx, y: min(startY, solidEnd)))
                context.stroke(line, with: .color(color.opacity((lane.status == .paused ? 0.5 : 0.95) * store.routeOpacity(lane.id))), style: StrokeStyle(lineWidth: store.routeLineWidth(lane.id, project: lane.isProject), lineCap: .round))
                if endY < solidEnd {
                    var future = Path(); future.move(to: CGPoint(x: lx, y: endY)); future.addLine(to: CGPoint(x: lx, y: solidEnd))
                    context.stroke(future, with: .color(color.opacity(0.65 * store.routeOpacity(lane.id))), style: StrokeStyle(lineWidth: store.routeLineWidth(lane.id, project: lane.isProject), lineCap: .round, dash: [5,5]))
                }
            }
            for (index, row) in rows.enumerated() {
                for event in row.events where event.kind == .merge || event.kind == .start {
                    guard let relation = store.workspace.routeRelations.first(where: { $0.entityID == event.entityID && $0.target == event.laneID }), let source = event.sourceLaneID, let sx = x(source), let tx = x(event.laneID), source != event.laneID else { continue }
                    let cy = centers[index]
                    let sourceColor = lanes.first(where: { $0.id == (event.kind == .merge ? source : event.laneID) })?.color ?? 0
                    var curve = Path()
                    curve.move(to: CGPoint(x: sx, y: cy + 22))
                    curve.addCurve(to: CGPoint(x: tx, y: cy), control1: CGPoint(x: sx, y: cy), control2: CGPoint(x: tx, y: cy + 22))
                    context.stroke(curve, with: .color(projectColor(sourceColor).opacity(store.relationExpanded(relation) ? 0.95 : 0.45 * min(store.routeOpacity(source), store.routeOpacity(event.laneID)))), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                }
            }
        }.frame(width: width, height: height).allowsHitTesting(false)
    }
}

private struct RoadmapDot: View {
    var color: Color
    var count: Int
    var symbol: String?
    var expanded: Bool
    var label: String
    var action: () -> Void
    @LocalState private var hovering = false
    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(Color(nsColor: .textBackgroundColor)).frame(width: 24, height: 24)
                if let symbol { Image(systemName: symbol).font(.system(size: 15, weight: .bold)).foregroundStyle(color) }
                else { Circle().fill(color).frame(width: count > 1 ? 22 : 14, height: count > 1 ? 22 : 14) }
                if count > 1 { Text("\(count)").font(.system(size: 10, weight: .bold)).foregroundStyle(.white) }
            }.frame(width: 28, height: 28).scaleEffect(hovering ? 1.35 : expanded ? 1.12 : 1)
                .shadow(color: color.opacity(hovering ? 0.30 : 0), radius: 5)
                .animation(.easeOut(duration: 0.14), value: hovering)
        }.buttonStyle(.plain).onHover { hovering = $0 }.help(label).accessibilityLabel(label)
    }
}
