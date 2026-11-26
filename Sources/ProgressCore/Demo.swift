import Foundation

extension Workspace {
    public static func demo(now: Date = Date()) -> Workspace {
        let calendar = Calendar.current
        func day(_ n: Int, hour: Int = 10) -> Date { calendar.date(bySettingHour: hour, minute: 0, second: 0, of: calendar.date(byAdding: .day, value: n, to: now)!)! }
        var result = Workspace()
        var launch = Project(title: "产品发布", color: 0); launch.createdAt = day(-18)
        launch.note = "准备一款效率工具的公开发布：设计体验、收集反馈、安排上线。项目与分支旁的 + 可以就地添加内容；时间轴上的三横杠可以调整排列。"
        var content = Project(title: "内容计划", color: 1); content.createdAt = day(-15)
        content.note = "整理介绍文章和使用指南，与产品发布共用用户反馈。共享分支保留同一份记录，向各项目分别合并成果。"
        var visual = Project(title: "视觉升级", color: 4); visual.createdAt = day(-40); visual.status = .completed; visual.closedAt = day(-10)
        visual.note = "视觉规范已交付。展开可回顾过程、合并结果与结束日期。"
        var event = Project(title: "活动筹备", color: 3); event.createdAt = day(-25); event.status = .paused
        event.note = "等待场地确认，暂时暂停。展开路线可以查看已有安排。"
        var migration = Project(title: "旧站迁移", color: 5); migration.createdAt = day(-65); migration.status = .archived; migration.closedAt = day(-35); migration.archivedAt = day(-30)
        migration.note = "迁移完成后归档，历史记录和成果仍可查阅。"
        result.projects = [launch, content, visual, event, migration]

        var design = Branch(title: "交互设计", projectIDs: [launch.id]); design.startAt = day(-12); design.originProjectID = launch.id; design.color = 6
        var feedback = Branch(title: "用户反馈", projectIDs: [launch.id, content.id]); feedback.startAt = day(-10); feedback.color = 2
        feedback.note = "反馈既用于改善交互，也用于完善介绍文章；分别合并到两个主干，保留各自的阶段摘要。"
        var writing = Branch(title: "内容撰写", projectIDs: [content.id]); writing.startAt = day(-9); writing.originProjectID = content.id; writing.color = 7
        var emptyState = Branch(title: "空状态方案", projectIDs: [launch.id]); emptyState.startAt = day(-6); emptyState.originBranchID = design.id; emptyState.color = 8
        emptyState.note = "从交互设计拉出的子分支。阶段成果可回到父分支，也可直接进入产品发布主干。"
        var ideas = Branch(title: "灵感收集"); ideas.startAt = day(-3); ideas.color = 9
        ideas.note = "尚未归属具体项目的方向；之后可编辑关联项目，或继续拉出子分支。"
        var style = Branch(title: "视觉规范", projectIDs: [visual.id]); style.startAt = day(-32); style.originProjectID = visual.id; style.color = 10; style.status = .completed; style.closedAt = day(-12)
        var venue = Branch(title: "场地方案", projectIDs: [event.id]); venue.startAt = day(-20); venue.originProjectID = event.id; venue.color = 11; venue.status = .paused
        var checklist = Branch(title: "迁移清单", projectIDs: [migration.id]); checklist.startAt = day(-60); checklist.originProjectID = migration.id; checklist.color = 12; checklist.status = .archived; checklist.closedAt = day(-36); checklist.archivedAt = day(-30)
        result.branches = [design, feedback, writing, emptyState, ideas, style, venue, checklist]

        func progress(_ title: String, _ offset: Int, body: String, project: UUID? = nil, branch: UUID? = nil, hour: Int = 10) -> WorkRecord {
            var record = WorkRecord(title: title); record.startAt = day(offset, hour: hour); record.createdAt = record.startAt; record.updatedAt = record.startAt
            record.projectIDs = project.map { [$0] } ?? []; record.branchID = branch; record.body = body
            return record
        }
        let findings = progress("反馈归纳", -3, body: "新用户更关心第一步如何开始。产品侧补充空状态引导，内容侧增加一页快速上手说明。", branch: feedback.id)
        let proposal = progress("引导方案定稿", -2, body: "采用一句说明和一个主要操作，让首次进入时知道下一步做什么。", branch: emptyState.id)
        let styleDelivery = progress("规范交付", -12, body: "整理了标题层级、强调色与常用组件，并附上使用说明。", branch: style.id)
        let migrationDelivery = progress("迁移验收", -36, body: "页面、附件与跳转清单完成核对，旧站保留只读记录。", branch: checklist.id)
        result.records = [
            progress("发布范围确认", -14, body: "本轮先完成核心流程与快速上手内容，其余方向进入后续计划。", project: launch.id),
            progress("内容主题确定", -11, body: "围绕工作规划、进度记录和阶段复盘组织文章。", project: content.id),
            progress("主流程评审", -4, body: "减少首次使用时的选择数量，保留随时补充细节的入口。", branch: design.id),
            progress("文案补充", -4, body: "同一天补充按钮与提示文案。脉络图可将相邻记录收在同一节点内，点击展开查看。", branch: design.id, hour: 15),
            progress("访谈摘记", -7, body: "整理了三类使用场景：独立推进、跨项目支持与阶段性交付。", branch: feedback.id),
            findings, proposal,
            progress("文章结构", -5, body: "先介绍使用场景，再给出操作路径，最后回答常见问题。", branch: writing.id),
            progress("桌面小组件构想", -1, body: "将今天的安排与待完成事项放在一个轻量入口中，先收集想法，暂不承诺实现。", branch: ideas.id),
            styleDelivery,
            progress("场地初筛", -18, body: "保留两个交通便利的候选场地，等待档期回复。", branch: venue.id),
            migrationDelivery
        ]
        var designTask = WorkRecord(kind: .task, title: "完善首次使用流程"); designTask.branchID = design.id; designTask.startAt = day(-3); designTask.dueAt = day(3); designTask.reminderDates = [day(2, hour: 9)]
        designTask.body = "结束日期暂不设置，先用 DDL 管理交付；仍可持续更新进度。"
        var article = WorkRecord(kind: .task, title: "完成介绍文章"); article.branchID = writing.id; article.startAt = day(-2); article.endAt = day(4); article.dueAt = day(4); article.reminderDates = [day(3, hour: 9)]
        article.body = "计划结束日期与截止日期分别保留；拖动时间轴可查看未来安排。"
        var publish = WorkRecord(kind: .task, title: "发布页面上线"); publish.projectIDs = [launch.id]; publish.startAt = day(4); publish.dueAt = day(6); publish.dependencies = [designTask.id, article.id]
        publish.body = "等待交互流程与介绍文章完成，演示跨分支任务依赖。"
        var overdue = WorkRecord(kind: .task, title: "补齐图片说明"); overdue.branchID = writing.id; overdue.startAt = day(-5); overdue.dueAt = day(-1); overdue.body = "截止日期已过，仍待补充；时间轴显示逾期标记。"
        var done = WorkRecord(kind: .task, title: "整理反馈标签"); done.branchID = feedback.id; done.startAt = day(-8); done.dueAt = day(-4); done.status = .completed; done.completedAt = day(-5)
        result.records += [designTask, article, publish, overdue, done].map { var value = $0; value.taskScheduled = true; return value }
        func meeting(_ title: String, _ offset: Int, projects: [UUID], repeatRule: RepeatRule = .none, hour: Int = 14) -> WorkRecord {
            var record = WorkRecord(kind: .meeting, title: title); record.projectIDs = projects; record.startAt = day(offset, hour: hour); record.endAt = record.startAt.addingTimeInterval(3600); record.repeatRule = repeatRule; record.reminderDates = [record.startAt.addingTimeInterval(-900)]
            record.body = repeatRule == .none ? "对齐交付范围和待办事项，提前 15 分钟提醒。示例空间不会发送系统通知。" : "按日历规则重复，保留本地时区；可选择仅本次、本次及以后或整个系列来编辑和删除。"
            return record
        }
        result.records += [
            meeting("发布协调会", 2, projects: [launch.id, content.id]),
            meeting("每周内容回顾", -7, projects: [content.id], repeatRule: .weekly),
            meeting("每日进展碰头", 1, projects: [launch.id], repeatRule: .daily, hour: 9),
            meeting("月度选题讨论", 5, projects: [content.id], repeatRule: .monthly)
        ]
        var toLaunch = MergeRecord(branchID: feedback.id, projectID: launch.id, summary: "将反馈中的首次使用问题纳入发布范围。", sourceRecordIDs: [findings.id]); toLaunch.date = day(-1, hour: 15)
        var toParent = MergeRecord(branchID: emptyState.id, targetBranchID: design.id, summary: "将空状态引导方案纳入交互设计。", sourceRecordIDs: [proposal.id]); toParent.date = day(-2, hour: 16)
        var styleMerge = MergeRecord(branchID: style.id, projectID: visual.id, summary: "视觉规范完成交付，分支结束。", sourceRecordIDs: [styleDelivery.id]); styleMerge.date = day(-12, hour: 16); styleMerge.closesBranch = true
        var archiveMerge = MergeRecord(branchID: checklist.id, projectID: migration.id, summary: "迁移清单验收完成，保留历史快照。", sourceRecordIDs: [migrationDelivery.id]); archiveMerge.date = day(-36, hour: 16); archiveMerge.closesBranch = true
        var toContent = MergeRecord(branchID: feedback.id, projectID: content.id, summary: "把反馈中的常见疑问整理进快速上手文章。", sourceRecordIDs: [findings.id]); toContent.date = day(0, hour: 9)
        result.merges = [toLaunch, toParent, styleMerge, archiveMerge, toContent]
        result.history = [ChangeRecord(entityID: visual.id, summary: "视觉规范交付，项目已完成。"), ChangeRecord(entityID: event.id, summary: "等待场地档期，项目暂停。"), ChangeRecord(entityID: migration.id, summary: "迁移验收后归档，历史记录继续保留。")]
        for i in result.history.indices { result.history[i].date = [day(-10), day(-15), day(-30)][i] }
        return result
    }
}
