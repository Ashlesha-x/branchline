import SwiftUI
import AppKit
import ProgressCore

private struct TimelineOccurrence {
    var record: WorkRecord
    var date: Date
}

private struct GraphLane: Identifiable {
    var id: UUID
    var project: Project?
    var branch: Branch?
    var records: [WorkRecord]
    var merges: [MergeRecord]
    var collapsed: Bool
    var summary = false
    var depth = 0
    var ownerProjectID: UUID?
    var groupStatus: WorkStatus?
    var taskFamilies: [UUID: UUID] = [:]
    var relationMarkers: [[RouteRelation]] = []
    var y: CGFloat = 0
    var height: CGFloat = 72
    var occurrences: [TimelineOccurrence] = []
    var title: String { project?.title ?? branch?.title ?? "" }
    var color: Color { projectColor(project?.color ?? branch?.color ?? 0) }
    var status: WorkStatus { project?.status ?? branch?.status ?? .active }
    var start: Date { project?.createdAt ?? branch?.startAt ?? Date() }
    var tasks: [WorkRecord] { records.filter { record in
        record.kind == .task && (!summary || ((record.status == .active || record.status == .paused) && (record.hasPlannedStart || record.dueAt != nil || record.endAt != nil)))
    } }
    var taskTrackIDs: [UUID] { tasks.reduce(into: [UUID]()) { ids, item in let key = item.taskSeriesID.map { taskFamilies[$0] ?? $0 } ?? item.id; if !ids.contains(key) { ids.append(key) } } }
    var events: [WorkRecord] { records.filter { $0.kind != .task } }
}

struct TimelineView: View {
    @Bindable var store: AppStore
    @LocalState private var scrollX: CGFloat = 0
    @LocalState private var ready = false
    @LocalState private var scrollY: CGFloat = 0
    @LocalState private var scrollPosition = ScrollPosition(x: 0)
    @LocalState private var verticalPosition = ScrollPosition(y: 0)
    @LocalState private var now = Date()
    @LocalState private var draggingRoute: UUID?
    @LocalState private var reorderTarget: UUID?
    @LocalState private var reorderAfter = false
    private let labelWidth: CGFloat = 180
    private let headerHeight: CGFloat = 50
    private var calendar: Calendar { .current }
    private var compact: Bool { store.mode == .graph }
    private var allDates: [Date] {
        var dates = store.filteredRecords.flatMap { [$0.startAt] + [$0.endAt, $0.dueAt].compactMap { $0 } } + store.workspace.merges.map(\.date) + store.workspace.branches.map(\.startAt) + store.workspace.projects.map(\.createdAt) + [now, store.focusDate]
        if compact {
            let interval = DateInterval(start: calendar.date(byAdding: .day, value: -30, to: store.focusDate)!, end: calendar.date(byAdding: .day, value: 60, to: store.focusDate)!)
            dates += store.filteredRecords.filter { $0.repeatRule != .none }.flatMap { CalendarLogic.occurrences(of: $0, in: interval) }
        }
        return dates
    }
    private var compactDays: [Date] { Array(Set(allDates.map { calendar.startOfDay(for: $0) })).sorted() }
    private var epoch: Date {
        let historical = calendar.date(byAdding: .day, value: -180, to: now)!
        return calendar.startOfDay(for: min(allDates.min() ?? historical, historical, calendar.date(byAdding: .day, value: -30, to: store.focusDate)!))
    }
    private var lastDay: Date { max(allDates.max() ?? now, calendar.date(byAdding: .day, value: 365, to: now)!, calendar.date(byAdding: .day, value: 60, to: store.focusDate)!) }
    private var count: Int { compact ? max(compactDays.count, 1) : (calendar.dateComponents([.day], from: epoch, to: lastDay).day ?? 365) + 1 }
    private var cellWidth: CGFloat { compact ? max(100, store.dayWidth) : store.dayWidth }
    private var contentWidth: CGFloat { CGFloat(count) * cellWidth }
    private func x(_ date: Date) -> CGFloat {
        let day = calendar.startOfDay(for: date)
        if compact { return CGFloat(compactDays.firstIndex(of: day) ?? compactDays.count) * cellWidth + cellWidth / 2 }
        return CGFloat(calendar.dateComponents([.day], from: epoch, to: day).day ?? 0) * cellWidth + cellWidth / 2
    }
    private func date(at index: Int) -> Date { compact ? compactDays[min(index, compactDays.count - 1)] : calendar.date(byAdding: .day, value: index, to: epoch)! }
    private var lanes: [GraphLane] {
        let records = store.filteredRecords
        let layout = store.routeLayout(in: .timeline)
        var result = layout.map { placement in
            let project = store.workspace.project(placement.id)
            let branch = store.workspace.branch(placement.id)
            let folded = project != nil && store.isCollapsed(placement.id, in: .timeline)
            return GraphLane(id: placement.id, project: project, branch: branch,
                records: records.filter { branch != nil ? $0.branchID == placement.id : $0.branchID == nil && $0.projectIDs.contains(placement.id) },
                merges: store.workspace.merges.filter { $0.targetLaneID == placement.id }, collapsed: folded,
                summary: folded || store.routeIsSummary(placement.id, in: .timeline), depth: placement.depth, ownerProjectID: placement.ownerProjectID, groupStatus: placement.groupStatus)
        }
        var y: CGFloat = headerHeight
        let interval = DateInterval(start: epoch, end: calendar.date(byAdding: .day, value: 1, to: lastDay)!)
        for index in result.indices {
            var occurrences: [TimelineOccurrence] = []
            result[index].taskFamilies = Dictionary(uniqueKeysWithValues: (store.workspace.taskPlans ?? []).map { ($0.id, $0.familyID ?? $0.id) })
            let lane = result[index]
            if lane.groupStatus != nil { result[index].height = 36; result[index].y = y; y += 36; continue }
            for record in lane.events {
                for date in store.workspace.timelineDates(of: record, in: interval, now: now, history: !lane.summary) {
                    occurrences.append(TimelineOccurrence(record: record, date: date))
                }
            }
            occurrences.sort { a, b in
                if a.date == b.date { return a.record.id.uuidString < b.record.id.uuidString }
                return a.date < b.date
            }
            result[index].occurrences = occurrences
            let grouped = Dictionary(grouping: result[index].occurrences.map(\.date) + result[index].merges.map(\.date), by: { calendar.startOfDay(for: $0) })
            let stack = grouped.values.map(\.count).max() ?? 1
            // Reserve only the occupied node tiers and task tracks. Keep heights
            // stable while panning horizontally so the route under the cursor stays put.
            // Keep the compact summary floor when opening history; expansion must never contract a route.
            result[index].height = 70 + CGFloat(max(0, stack - 1)) * 34 + CGFloat(result[index].taskTrackIDs.count) * 24
            result[index].y = y; y += result[index].height
        }
        let relations = store.workspace.routeRelations.filter { relation in
            guard let source = result.firstIndex(where: { $0.id == relation.source }), let target = result.firstIndex(where: { $0.id == relation.target }) else {
                return result.contains { $0.id == relation.source || $0.id == relation.target }
            }
            return abs(source - target) > 1 || result[source].ownerProjectID != result[target].ownerProjectID || result[source].height > 160 || result[target].height > 160
        }
        y = headerHeight
        for index in result.indices {
            let endpoints = relations.filter { $0.source == result[index].id || $0.target == result[index].id }
            result[index].relationMarkers = Dictionary(grouping: endpoints, by: { calendar.startOfDay(for: $0.date) }).sorted { $0.key < $1.key }.map { $0.value.sorted { $0.id < $1.id } }
            result[index].y = y; y += result[index].height
        }
        return result
    }
    var body: some View {
        GeometryReader { geometry in
            let rows = lanes
            let height = (rows.last.map { $0.y + $0.height } ?? 200) + 20
            let viewportWidth = max(100, geometry.size.width - labelWidth - 16)
            let viewportHeight = max(100, geometry.size.height - 56)
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                ScrollView(.vertical) {
                    HStack(alignment: .top, spacing: 0) {
                        VStack(spacing: 0) {
                            HStack { Text(compact ? "工作线索" : "项目 / 分支").font(.caption).foregroundStyle(.secondary); Spacer() }.padding(.leading, 14).frame(height: headerHeight).background(Color(nsColor: .controlBackgroundColor)).offset(y: scrollY).zIndex(4)
                            ForEach(rows) { lane in laneLabel(lane).frame(height: lane.height) }
                        }.frame(width: labelWidth).background(Color(nsColor: .controlBackgroundColor)).coordinateSpace(name: "routeLabels")
                        ScrollView(.horizontal) {
                            Color.clear.frame(width: max(contentWidth, viewportWidth), height: height)
                                .background(NativeScrollIndicatorHider())
                                .overlay(alignment: .topLeading) {
                                    plot(rows: rows, width: viewportWidth, height: height)
                                        .frame(width: viewportWidth, height: height).clipped().offset(x: scrollX)
                                }
                        }
                        .scrollIndicators(.hidden)
                        .scrollPosition($scrollPosition)
                        .onScrollGeometryChange(for: CGFloat.self) { max(0, $0.contentOffset.x) } action: { _, value in scrollX = value; if ready { store.trackViewport("timeline", x: value) } }
                        .frame(width: viewportWidth, height: height)
                    }
                }
                .scrollIndicators(.hidden)
                .scrollPosition($verticalPosition)
                .onScrollGeometryChange(for: CGFloat.self) { max(0, $0.contentOffset.y) } action: { _, value in scrollY = value; if ready { store.trackViewport("timeline", y: value) } }
                PersistentScroller(offset: scrollY, contentLength: height, viewportLength: viewportHeight) { verticalPosition.scrollTo(y: $0) }.frame(width: 16)
                }
                HStack(spacing: 0) {
                    Color(nsColor: .controlBackgroundColor).frame(width: labelWidth, height: 16)
                    PersistentScroller(horizontal: true, offset: scrollX, contentLength: max(contentWidth, viewportWidth), viewportLength: viewportWidth) { scrollPosition.scrollTo(x: $0) }.frame(height: 16)
                    Color(nsColor: .controlBackgroundColor).frame(width: 16, height: 16)
                }
                Divider()
                HStack(spacing: 16) {
                    Label("已记录", systemImage: "circle.fill")
                    Label("计划", systemImage: "circle")
                    Label("合并", systemImage: "diamond.fill")
                    Spacer()
                    if store.pinnedRelationID != nil { Button("取消固定连线") { store.pinnedRelationID = nil } }
                }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 11)
            }
            .onAppear {
                if store.viewportToRestore("timeline") == nil { navigate(width: viewportWidth) }
            }
            .task(id: store.browseRestoreToken) {
                let offset = store.viewportToRestore("timeline")
                await Task.yield(); guard !Task.isCancelled else { return }
                if store.revealBrowseSelection, let target = selectedBrowseTarget {
                    scrollPosition.scrollTo(x: max(0, x(target.date) - viewportWidth * 0.5))
                    verticalPosition.scrollTo(y: max(0, target.y - 24))
                }
                else if let offset { scrollPosition.scrollTo(x: offset.x); verticalPosition.scrollTo(y: offset.y) }
                else { navigate(width: viewportWidth) }
                ready = true
            }
            .onChange(of: store.selection) { _, selection in
                guard ready, store.restoreOffsets.isEmpty, case .branch(let id) = selection,
                      store.workspace.branchIsIndependent(id), let lane = rows.first(where: { $0.id == id }) else { return }
                if lane.y < scrollY + headerHeight || lane.y > scrollY + viewportHeight - 70 {
                    verticalPosition.scrollTo(y: max(0, lane.y - headerHeight))
                }
            }
            .onChange(of: store.navigationToken) { _, _ in navigate(width: viewportWidth) }
            .onChange(of: store.dayWidth) { _, _ in navigate(width: viewportWidth) }
        }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { now = $0 }
    }
    private var selectedBrowseTarget: (date: Date, y: CGFloat)? {
        guard let id = store.selectedEntityID else { return nil }
        let record = store.workspace.record(id)
        let merge = store.workspace.merges.first { $0.id == id }
        let laneID = record?.branchID ?? record?.projectIDs.first(where: { store.projectFilter == nil || $0 == store.projectFilter }) ?? merge?.targetBranchID ?? merge?.projectID ?? id
        guard let lane = lanes.first(where: { $0.id == laneID }) else { return nil }
        let date = store.selectedOccurrence ?? record?.startAt ?? merge?.date ?? lane.branch?.startAt ?? lane.project?.createdAt ?? store.focusDate
        return (date, lane.y)
    }
    private func navigate(width: CGFloat) {
        let target = max(0, x(store.focusDate) - width * 0.62)
        scrollPosition.scrollTo(x: target)
        if case .branch(let id) = store.selection, store.workspace.branchIsIndependent(id), let lane = lanes.first(where: { $0.id == id }) {
            verticalPosition.scrollTo(y: max(0, lane.y - headerHeight))
        }
    }
    @ViewBuilder private func laneLabel(_ lane: GraphLane) -> some View {
        if let status = lane.groupStatus {
            RouteStatusButton(store: store, status: status, scope: .timeline, compact: true).background(Color(nsColor: .controlBackgroundColor))
        } else {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                if lane.project != nil {
                    Button { store.toggleCollapsed(lane.id, in: .timeline) } label: { Image(systemName: lane.collapsed ? "chevron.right" : "chevron.down").font(.caption).frame(width: 12) }.buttonStyle(.plain).accessibilityLabel("\(lane.collapsed ? "展开" : "折叠")\(lane.title)")
                } else {
                    Button { store.toggleRouteDetails(lane.id, in: .timeline) } label: { Image(systemName: lane.summary ? "chevron.right" : "chevron.down").font(.caption).frame(width: 12) }.buttonStyle(.plain).accessibilityLabel("\(lane.summary ? "展开历史" : "收起历史")：\(lane.title)")
                }
                Image(systemName: lane.project != nil ? "folder.fill" : store.branchSymbol(lane.id))
                    .font(.system(size: 11)).foregroundStyle(lane.color).frame(width: 13)
                Button { store.browse { store.selection = lane.project != nil ? .project(lane.id) : .branch(lane.id) } } label: { Text(lane.title).fontWeight(lane.project != nil ? .medium : .regular).multilineTextAlignment(.leading).lineLimit(1) }.buttonStyle(.plain).opacity(store.searchOpacity(lane.id)).help(lane.title)
                Spacer(minLength: 0)
                Image(systemName: "line.3.horizontal").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    .frame(width: 18, height: 22).contentShape(Rectangle())
                    .help("按住拖动调整顺序；只调整排序，不改变关联")
                    .accessibilityLabel("拖动排序：\(lane.title)")
                    .highPriorityGesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("routeLabels"))
                        .onChanged { value in
                            draggingRoute = lane.id
                            updateReorderTarget(source: lane.id, y: value.location.y)
                        }
                        .onEnded { value in
                            updateReorderTarget(source: lane.id, y: value.location.y)
                            if let target = reorderTarget { store.reorderRoute(lane.id, relativeTo: target, after: reorderAfter) }
                            draggingRoute = nil; reorderTarget = nil
                        })
            }
            let badges = [
                lane.status == .active ? nil : lane.status.title,
                lane.branch.flatMap { $0.projectIDs.count > 1 ? "共享 · \($0.projectIDs.count) 个项目" : nil }
            ].compactMap { $0 }
            if !badges.isEmpty {
                Text(badges.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary).lineLimit(1).padding(.leading, 17)
            }
            Spacer(minLength: 0)
        }.padding(.leading, 10 + (lane.project == nil ? CGFloat(min(lane.depth + (lane.ownerProjectID == nil ? 0 : 1), 4)) * 14 : 0)).padding(.trailing, 8).padding(.top, 10).frame(maxWidth: .infinity, alignment: .leading)
            .background(lane.id == draggingRoute ? Color.accentColor.opacity(0.08) : .clear)
            .overlay(alignment: .bottom) { Divider() }
            .overlay(alignment: reorderAfter ? .bottom : .top) {
                if reorderTarget == lane.id { Rectangle().fill(Color.accentColor).frame(height: 3).allowsHitTesting(false) }
            }
        }
    }
    private func updateReorderTarget(source: UUID, y: CGFloat) {
        guard let target = lanes.first(where: { y >= $0.y && y < $0.y + $0.height }), target.groupStatus == nil, store.canReorderRoute(source, relativeTo: target.id) else {
            reorderTarget = nil; return
        }
        reorderTarget = target.id; reorderAfter = y > target.y + target.height / 2
    }
    private func plot(rows: [GraphLane], width: CGFloat, height: CGFloat) -> some View {
        let first = max(0, Int(scrollX / cellWidth) - 1), last = min(count - 1, Int((scrollX + width) / cellWidth) + 1)
        let range = first <= last ? Array(first...last) : []
        let positions = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        return ZStack(alignment: .topLeading) {
            Canvas { context, size in
                if store.isSearching { context.opacity = 0.3 }
                for index in range {
                    let day = date(at: index), left = CGFloat(index) * cellWidth - scrollX
                    let weekend = calendar.isDateInWeekend(day)
                    if weekend {
                        context.fill(Path(CGRect(x: left, y: 0, width: cellWidth, height: size.height)), with: .color(.primary.opacity(0.028)))
                    }
                    var border = Path(); border.move(to: CGPoint(x: left, y: 0)); border.addLine(to: CGPoint(x: left, y: size.height)); context.stroke(border, with: .color(.primary.opacity(0.045)), lineWidth: 0.5)
                }
                for lane in rows where lane.groupStatus == nil {
                    var separator = Path(); separator.move(to: CGPoint(x: 0, y: lane.y + lane.height)); separator.addLine(to: CGPoint(x: width, y: lane.y + lane.height)); context.stroke(separator, with: .color(.primary.opacity(0.07)), lineWidth: 0.5)
                    let start = x(lane.start) - scrollX, y = lane.y + 20
                    let actualEnd = lane.project?.closedAt ?? lane.project?.archivedAt ?? lane.branch?.closedAt ?? lane.branch?.archivedAt ?? now
                    let end = max(start, x(actualEnd) - scrollX)
                    var line = Path(); line.move(to: CGPoint(x: start, y: y)); line.addLine(to: CGPoint(x: end, y: y)); context.stroke(line, with: .color(lane.color.opacity((lane.status == .paused ? 0.45 : 0.85) * store.routeOpacity(lane.id))), style: StrokeStyle(lineWidth: store.routeLineWidth(lane.id, project: lane.project != nil), lineCap: .round, dash: lane.status == .paused ? [4,4] : []))
                    let futureEnd = (lane.records.flatMap { [$0.startAt, $0.endAt, $0.dueAt].compactMap { $0 } } + lane.merges.map(\.date)).max() ?? actualEnd
                    if futureEnd > actualEnd {
                        var future = Path(); future.move(to: CGPoint(x: end, y: y)); future.addLine(to: CGPoint(x: x(futureEnd) - scrollX, y: y)); context.stroke(future, with: .color(lane.color.opacity(0.65 * store.routeOpacity(lane.id))), style: StrokeStyle(lineWidth: store.routeLineWidth(lane.id, project: lane.project != nil), dash: [5,4]))
                    }
                }
                let longIDs = Set(rows.flatMap(\.relationMarkers).flatMap { $0 }.map(\.id))
                for relation in store.workspace.routeRelations {
                    guard let source = positions[relation.source], let target = positions[relation.target], !longIDs.contains(relation.id) || store.relationExpanded(relation) else { continue }
                    let tx = x(relation.date) - scrollX
                    let sourceX = tx - min(cellWidth * 0.45, 45)
                    let targetY = target.y + 20 + (relation.kind == .merge ? CGFloat(target.merges.first(where: { $0.id == relation.entityID }).map { mergeStack($0, lane: target) } ?? 0) * 34 : 0)
                    let from = CGPoint(x: sourceX, y: source.y + 20)
                    let to = CGPoint(x: tx, y: targetY)
                    // Give both horizontal joins equal room to turn, at every time scale.
                    let tangent = (to.x - from.x) * 0.65
                    var path = Path(); path.move(to: from)
                    path.addCurve(to: to, control1: CGPoint(x: from.x + tangent, y: from.y), control2: CGPoint(x: to.x - tangent, y: to.y))
                    let color = relation.kind == .merge ? source.color : target.color
                    let opacity = store.relationExpanded(relation) ? 0.95 : 0.45 * min(store.routeOpacity(source.id), store.routeOpacity(target.id))
                    context.stroke(path, with: .color(color.opacity(opacity)), style: StrokeStyle(lineWidth: store.relationExpanded(relation) ? 3 : 2, lineCap: .round))
                    if store.relationExpanded(relation) {
                        for point in [from, to] {
                            context.stroke(Path(ellipseIn: CGRect(x: point.x - 8, y: point.y - 8, width: 16, height: 16)), with: .color(color.opacity(0.7)), lineWidth: 2)
                        }
                    }
                }
                let todayX = x(now) - scrollX
                if todayX >= 0 && todayX <= width {
                    var line = Path(); line.move(to: CGPoint(x: todayX, y: headerHeight)); line.addLine(to: CGPoint(x: todayX, y: size.height)); context.stroke(line, with: .color(.blue.opacity(0.7)), lineWidth: 1)
                }
            }.allowsHitTesting(false)
            Rectangle().fill(Color(nsColor: .controlBackgroundColor)).frame(width: width, height: headerHeight).offset(y: scrollY).zIndex(3)
            ForEach(range, id: \.self) { index in
                let day = date(at: index), today = calendar.isDate(day, inSameDayAs: now)
                VStack(spacing: 5) {
                    Text(today ? "今天" : day.formatted(.dateTime.month(.twoDigits).day(.twoDigits).locale(Locale(identifier: "zh_CN")))).font(.caption).foregroundStyle(today ? Color.white : Color.secondary).padding(.horizontal, 7).padding(.vertical, 3).background(today ? Color.blue : .clear, in: Capsule())
                    Text(day.formatted(.dateTime.weekday(.abbreviated).locale(Locale(identifier: "zh_CN")))).font(.caption2).foregroundStyle(.secondary)
                }.frame(width: cellWidth, height: headerHeight).position(x: CGFloat(index) * cellWidth + cellWidth / 2 - scrollX, y: headerHeight / 2 + scrollY).zIndex(4)
            }
            ForEach(rows.filter { $0.groupStatus != nil }) { lane in
                if let status = lane.groupStatus {
                    RouteStatusButton(store: store, status: status, scope: .timeline, showTitle: false)
                        .frame(width: width, height: lane.height).background(Color(nsColor: .controlBackgroundColor))
                        .position(x: width / 2, y: lane.y + lane.height / 2)
                }
            }
            ForEach(rows.filter { $0.groupStatus == nil }) { lane in
                Group {
                    let startX = x(lane.start) - scrollX
                    if startX >= -12 && startX <= width + 12 {
                        Button { store.browse { store.selection = lane.project != nil ? .project(lane.id) : .branch(lane.id) } } label: {
                            Circle().fill(lane.color).frame(width: 14, height: 14).overlay { Circle().stroke(Color(nsColor: .textBackgroundColor), lineWidth: 2) }.frame(width: 24, height: 24)
                        }.buttonStyle(.plain).opacity(store.searchOpacity(lane.id)).position(x: startX, y: lane.y + 20).help("起点：\(lane.title) · \(fullDate(lane.start))").accessibilityLabel("\(lane.title)开始日期")
                    }
                    if lane.summary {
                        HStack(spacing: 8) {
                            RouteSummaryText(store: store, routeID: lane.id, now: now)
                            Spacer(minLength: 4)
                            if lane.project != nil && !lane.collapsed { Button("展开历史") { store.toggleRouteDetails(lane.id, in: .timeline) }.buttonStyle(.plain).foregroundStyle(.tint).font(.caption2).accessibilityLabel("展开历史：\(lane.title)") }
                        }.padding(.horizontal, 12).frame(width: width, height: 22).position(x: width / 2, y: lane.y + lane.height - 12)
                    } else if lane.project != nil {
                        Button("收起历史") { store.toggleRouteDetails(lane.id, in: .timeline) }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary).position(x: 35, y: lane.y + lane.height - 12)
                    }
                    ForEach(lane.relationMarkers, id: \.first!.id) { relations in
                        if let relation = relations.first {
                            let mx = x(relation.date) - scrollX
                            if mx > -cellWidth && mx < width + cellWidth {
                                let outgoing = relation.source == lane.id
                                let stack = outgoing ? 0 : (relation.kind == .merge ? lane.merges.first(where: { $0.id == relation.entityID }).map { mergeStack($0, lane: lane) } ?? 0 : 0)
                                RouteRelationMarker(store: store, relations: relations, laneID: lane.id, color: projectColor(store.workspace.branch(relation.kind == .merge ? relation.source : relation.target)?.color ?? 0), width: lane.summary ? 22 : max(34, min(116, cellWidth - 8)), iconOnly: lane.summary)
                                    .position(x: mx - (outgoing ? min(cellWidth * 0.45, 45) : 0), y: lane.y + 20 + CGFloat(stack) * 34 + (outgoing ? -12 : 15))
                            }
                        }
                    }
                    eventNodes(lane: lane, width: width)
                    ForEach(Array(lane.tasks.enumerated()), id: \.element.id) { index, task in
                        taskBar(task, lane: lane, index: lane.taskTrackIDs.firstIndex(of: store.workspace.taskFamilyID(for: task) ?? task.id) ?? index, width: width)
                    }
                    ForEach(lane.merges) { merge in
                        let mx = x(merge.date) - scrollX
                        if mx > -cellWidth && mx < width + cellWidth {
                            Button { store.browse { store.selection = .merge(merge.id) } } label: {
                                Image(systemName: "diamond.fill").font(.system(size: 14)).foregroundStyle(lane.color).frame(width: 24, height: 24).background(Color(nsColor: .textBackgroundColor), in: Circle())
                                    .overlay(alignment: .top) {
                                        if !lane.summary && !lane.relationMarkers.flatMap({ $0 }).contains(where: { $0.entityID == merge.id }) {
                                            Text("成果合并").font(.caption2).lineLimit(1).frame(width: cellWidth - 8).offset(y: 21)
                                        }
                                    }
                            }.buttonStyle(.plain).opacity(store.searchOpacity(merge.id)).position(x: mx, y: lane.y + 20 + CGFloat(mergeStack(merge, lane: lane)) * 34).help(merge.summary).accessibilityLabel("合并：\(merge.summary)")
                        }
                    }
                }
            }
        }.background(Color(nsColor: .textBackgroundColor))
    }
    @ViewBuilder private func eventNodes(lane: GraphLane, width: CGFloat) -> some View {
        let start = date(at: max(0, min(count - 1, Int(scrollX / cellWidth) - 1)))
        let end = calendar.date(byAdding: .day, value: 1, to: date(at: max(0, min(count - 1, Int((scrollX + width) / cellWidth) + 1))))!
        let events = lane.occurrences.filter { $0.date >= start && $0.date < end }
        // Pick an occurrence inside the viewport, not the padded rendering range.
        // Selecting another occurrence moves the series label to that marker.
        let visibleSeries = Dictionary(grouping: events.filter {
            $0.record.repeatRule != .none && x($0.date) - scrollX >= 0 && x($0.date) - scrollX <= width
        }, by: { $0.record.id })
        let titleAnchors = visibleSeries.mapValues { values in
            let selected = values.first { pair in
                store.selection == .record(pair.record.id) && store.selectedOccurrence.map { abs($0.timeIntervalSince(pair.date)) < 1 } == true
            }
            let inset = (cellWidth - 10) / 2
            let fullyVisible = values.first { x($0.date) - scrollX >= inset && x($0.date) - scrollX <= width - inset }
            return selected?.date ?? fullyVisible?.date ?? values[0].date
        }
        ForEach(Array(events.enumerated()), id: \.offset) { index, pair in
            let record = pair.record, occurrence = pair.date
            let stack = events.prefix(index).filter { calendar.isDate($0.date, inSameDayAs: occurrence) }.count + lane.merges.filter { calendar.isDate($0.date, inSameDayAs: occurrence) && $0.date < occurrence }.count
            let nx = x(occurrence) - scrollX
            let showTitle = record.repeatRule == .none || titleAnchors[record.id] == occurrence
            let selected = store.selection == .record(record.id) && (record.repeatRule == .none || (store.selectedOccurrence.map { abs($0.timeIntervalSince(occurrence)) < 1 } ?? showTitle))
            Button { store.browse { store.selection = .record(record.id); store.selectedOccurrence = occurrence } } label: {
                Image(systemName: record.kind == .task ? "flag.fill" : record.kind == .meeting ? "calendar" : (occurrence > now ? "circle" : "circle.fill"))
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(lane.color)
                    .frame(width: 24, height: 24).background(Color(nsColor: .textBackgroundColor), in: Circle())
                    .overlay { if selected { Circle().stroke(lane.color.opacity(0.35), lineWidth: 3) } }
                    .overlay(alignment: .top) { if showTitle { Text(record.title).font(.system(size: 12)).lineLimit(1).frame(width: cellWidth - 10).offset(y: 21) } }
            }.buttonStyle(.plain).opacity(store.searchOpacity(record.id)).position(x: nx, y: lane.y + 20 + CGFloat(stack) * 34).help("\(record.title)\n\(fullDate(occurrence))\n\(record.body)").accessibilityLabel("\(record.title)，\(shortDate(occurrence))")
        }
    }
    private func mergeStack(_ merge: MergeRecord, lane: GraphLane) -> Int {
        lane.occurrences.filter { calendar.isDate($0.date, inSameDayAs: merge.date) && $0.date <= merge.date }.count + lane.merges.filter { calendar.isDate($0.date, inSameDayAs: merge.date) && ($0.date < merge.date || ($0.date == merge.date && $0.id.uuidString < merge.id.uuidString)) }.count
    }
    @ViewBuilder private func taskBar(_ record: WorkRecord, lane: GraphLane, index: Int, width: CGFloat) -> some View {
        let anchor = record.hasPlannedStart ? record.startAt : record.dueAt ?? record.createdAt
        let left = x(anchor) - scrollX
        let actualEnd = record.taskSeriesID != nil ? anchor : (record.hasPlannedStart ? record.completedAt ?? record.endAt ?? max(now, record.startAt) : anchor)
        let right = x(actualEnd) - scrollX
        let visibleLeft = max(0, left), visibleRight = min(width, max(right, left + 26))
        let y = lane.y + lane.height - CGFloat(lane.taskTrackIDs.count - index) * 24 + 6 - (lane.summary ? 20 : 0)
        let visibleSeriesTasks = record.taskSeriesID == nil ? [] : lane.tasks.filter { candidate in
            let date = candidate.hasPlannedStart ? candidate.startAt : candidate.dueAt ?? candidate.createdAt
            return store.workspace.taskFamilyID(for: candidate) == store.workspace.taskFamilyID(for: record) && x(date) - scrollX >= 0 && x(date) - scrollX <= width
        }
        let titleOwner = visibleSeriesTasks.first { store.selection == .record($0.id) } ?? visibleSeriesTasks.first
        let showTitle = record.taskSeriesID == nil || titleOwner?.id == record.id
        let title = record.hasPlannedStart ? record.title : (record.dueAt == nil ? "录入 · " : "截止 · ") + record.title
        let textWidth = (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width + 4
        let barWidth = max(0, visibleRight - visibleLeft)
        let flagX = record.dueAt.map { x($0) - scrollX }
        let rightSpace = max(0, min(width - visibleRight - 10, flagX.map { $0 >= visibleRight - 4 ? $0 - visibleRight - 18 : width } ?? width))
        let leftSpace = max(0, min(visibleLeft - 10, flagX.map { $0 <= visibleLeft + 4 ? visibleLeft - $0 - 18 : width } ?? width))
        let short = barWidth < min(textWidth + 44, 260) || (flagX.map { $0 > visibleLeft && $0 < visibleLeft + min(barWidth, textWidth + 44) } ?? false)
        let outsideRight = short && rightSpace >= min(textWidth, 56)
        let outsideLeft = short && !outsideRight && leftSpace >= min(textWidth, 56)
        let external = outsideRight || outsideLeft
        let titleWidth = min(260, textWidth, outsideRight ? rightSpace : leftSpace)
        let help = record.hasPlannedStart ? "\(record.title)\n计划开始：\(fullDate(record.startAt))\n计划结束：\(record.endAt.map(fullDate) ?? "未设置")" : "\(record.title)\n未安排计划日期；按\(record.dueAt == nil ? "录入" : "截止")日期定位，不表示任务工期。"
        if visibleRight > visibleLeft && right >= 0 && left <= width {
            Button { store.browse { store.selection = .record(record.id) } } label: {
                HStack(spacing: 5) {
                    Image(systemName: record.status == .completed ? "checkmark.circle.fill" : (store.workspace.blockedBy(record).isEmpty ? "circle" : "hourglass"))
                    if showTitle && !external && barWidth > 54 { Text(title).lineLimit(1); Spacer(minLength: 0) }
                    if barWidth > 70 && record.hasPlannedStart && record.endAt == nil && record.completedAt == nil { Image(systemName: "arrow.right").font(.caption2) }
                }.font(.system(size: 12)).padding(.horizontal, 7).frame(width: barWidth, height: 22).background(lane.color.opacity(store.selection == .record(record.id) ? 0.22 : 0.11), in: RoundedRectangle(cornerRadius: 5))
            }.buttonStyle(.plain).opacity(store.searchOpacity(record.id)).position(x: (visibleRight + visibleLeft) / 2, y: y).help(help).accessibilityLabel(record.title)
            if external && showTitle {
                Button { store.browse { store.selection = .record(record.id) } } label: {
                    Text(title).font(.system(size: 12)).lineLimit(1).frame(width: titleWidth, height: 22, alignment: outsideRight ? .leading : .trailing).contentShape(Rectangle())
                }.buttonStyle(.plain).help(help).accessibilityLabel("任务标题：" + record.title)
                    .position(x: outsideRight ? visibleRight + 7 + titleWidth / 2 : visibleLeft - 7 - titleWidth / 2, y: y)
            }
        }
        if let due = record.dueAt {
            let dx = x(due) - scrollX
            if dx >= 0 && dx <= width {
                Button { store.browse { store.selection = .record(record.id) } } label: { Image(systemName: "flag.fill").foregroundStyle(record.status == .completed ? Color.secondary : CalendarLogic.deadlinePassed(record, now: now) ? Color.red : Color.orange).font(.caption) }.buttonStyle(.plain).opacity(store.searchOpacity(record.id)).position(x: dx, y: y).help("DDL：\(record.title) · \(fullDate(due))").accessibilityLabel("截止日期：\(record.title)")
            }
        }
    }
}

