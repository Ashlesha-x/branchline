import Foundation
import ProgressCore

struct CheckFailure: Error, CustomStringConvertible { var description: String }
func expect(_ condition: @autoclosure () throws -> Bool, file: String = #file, line: Int = #line) throws {
    if try !condition() { throw CheckFailure(description: "Assertion failed at \(URL(fileURLWithPath: file).lastPathComponent):\(line)") }
}
func require<T>(_ optional: T?, file: String = #file, line: Int = #line) throws -> T {
    guard let value = optional else { throw CheckFailure(description: "Required value missing at \(file):\(line)") }; return value
}
func expectThrows(_ body: () throws -> Void) throws {
    do { try body() } catch is WorkspaceError { return }
    throw CheckFailure(description: "Expected WorkspaceError was not thrown")
}

@main struct VerificationRunner {
    @MainActor static func main() {
        let cases: [(String, @MainActor () throws -> Void)] = [
            ("app versions compare numerically and rank prereleases", appVersionsCompareNumericallyAndRankPrereleases),
            ("update decision picks installable package", updateDecisionPicksInstallablePackage),
            ("release JSON digest and download trust rules", releaseJSONDecodesDigestAndTrustRules),
            ("review presets roll forward while prior draft remains recoverable", reviewPresetsRollForwardKeepingDraft),
            ("brief review groups work and carries material links", briefReviewGroupsWorkAndCarriesMaterials),
            ("reminder queue refills and targets edited occurrence", reminderQueueRefillsAndTargetsEditedOccurrence),
            ("recurring task independent completion and materialization", recurringTasksHaveIndependentStatesAndStableMaterialization),
            ("recurring task deletion and plan trash restoration", recurringTaskDeletionAndTrashRetainPlans),
            ("calendar sync deduplication and local-change conflicts", calendarSyncDeduplicatesAndPreservesLocalEdits),
            ("iCloud backup names and retention", iCloudBackupNamesAndRetentionKeepRecentAndMonthly),
            ("daily backup status next run and skip", dailyBackupStatusReportsNextRunAndSkips),
            ("short dates drop the current year", shortDatesDropCurrentYearAndKeepOthers),
            ("calendar write-back candidates and notes", calendarWriteBackCandidatesAndNotes),
            ("workspace registry names and deletion guards", workspaceRegistryValidatesNamesAndGuardsDeletion),
            ("calendar recurrence identity and fixed reminder protection", calendarSyncKeepsOccurrenceIdentityAndProtectsFixedReminders),
            ("review manual edits undo reopen and migration", reviewEditsUndoAndMigrationSurviveReopen),
            ("review separates occurred and upcoming meetings", reviewSeparatesPastAndFutureMeetings),
            ("following tasks retain history identities and notes", followingTasksPreserveHistoryIdentityAndNotes),
            ("following frequency excludes completed slots", followingFrequencyChangeDoesNotRegenerateCompletedSlots),
            ("calendar field resolution baseline and stale guard", calendarResolutionUpdatesBaselineAndRejectsStaleEdits),
            ("calendar cancellation preserves history and reminders", calendarCancellationPreservesHistoryAndStopsReminders),
            ("migration backup draft roundtrip and legacy", migrationBackupPreservesDraftsAndReadsLegacy),
            ("migration restore journal rollback and recovery", migrationJournalRollsBackAndRecoversBothStores),
            ("review occurrence completion and late entry", reviewsSeparateOccurrenceCompletionAndLateEntry),
            ("compound record filters and date meaning", compoundFiltersRespectDateMeaningAndTaskState),
            ("draft disk reopen, clear and corruption preservation", recordDraftsSurviveReopenAndClearWithoutRemovingFile),
            ("draft conflict and saved-write precision", draftConflictAndCommitChecksRespectWorkspaceDatePrecision),
            ("draft recurrence scope independence", recurringDraftScopesRemainIndependent),
            ("independent root ordering preserves ownership", rootOrderMovesIndependentRoutesWithoutReparenting),
            ("inactive project groups fold and retain routes", inactiveProjectGroupsFoldAndRetainTheirOwnRoutes),
            ("daily dirty backup and missed-run boundaries", dailyBackupsRespectDirtyDaysAndCatchUp),
            ("expanded timeline retains future and ongoing meetings", expandedTimelineNeverLosesFutureOccurrences),
            ("route hierarchy and sibling order", routeHierarchyKeepsSiblingsAndSharedWorkUnique),
            ("shared route placement under filtering and collapse", sharedRouteOwnerSurvivesProjectOrderAndCollapse),
            ("route summary pending and deadline boundaries", routeSummaryPreservesDeadlineMeaningAndCounts),
            ("overview retains merges, deadlines and chronology", overviewKeepsMilestonesAndDeadlinesWithoutDailyNoise),
            ("relation pairs preserve source, destination and identity", relationPairsRemainDistinctAcrossTargetsAndDates),
            ("automation atomic references and durable replay", automationAtomicReferencesAndReplay),
            ("automation stale revisions and rollback", automationConflictsAndRollback),
            ("automation patch preserves unrelated fields and validates", automationPatchAndValidation),
            ("automation dependency and reminder policies", automationDependenciesAndReminders),
            ("automation scoped reads and pagination", automationScopedReadsAndPagination),
            ("automation persistence and writer lock", automationPersistenceAndSingleWriter),
            ("automation merge and recurrence boundaries", automationMergeAndRecurrenceBoundaries),
            ("shared branch uniqueness", demoIsValidAndSharedBranchIsUnique),
            ("backup links and immutable summary", backupPreservesLinksAndImmutableMergeSummary),
            ("dependency cycle rejection", dependencyCycleIsRejectedAcrossBranches),
            ("invalid backup and dangling references", invalidBackupCannotLeaveDanglingReferences),
            ("open-ended tasks and reversed dates", datesAllowOpenEndedTasksButRejectReverseIntervals),
            ("date-only deadline boundary", dateOnlyDeadlineExpiresAfterItsLocalDay),
            ("recurrence across daylight saving", recurringMeetingKeepsWallClockAcrossDaylightSaving),
            ("recurrence across years", recurrenceCanJumpYearsWithoutLosingFirstVisibleOccurrence),
            ("disk reopen and failed-write preservation", persistenceSurvivesRepositoryRecreationAndRejectsBadWrites),
            ("personal/demo isolation", demoAndPersonalRepositoriesAreIsolated),
            ("closure and archive after every merge", closureDatesRespectLatestMerge),
            ("legacy backup without closure fields", legacyBackupWithoutClosureDates),
            ("route color allocation and archival reuse", routeColorsAvoidOccupiedAndReleaseArchived),
            ("complete roadmap and collapsed shared lanes", roadmapPreservesRoutesAndGroupsRecords),
            ("project deletion preserves shared work", deletingProjectPreservesSharedWork),
            ("branch deletion cleans references", deletingBranchClearsDependenciesAndMerges),
            ("record deletion preserves merge snapshots", deletingRecordPreservesMergeSnapshotAndSeriesSafety),
            ("deletion persistence and backup restoration", deletionPersistsAndBackupRestores),
            ("nested branches, parent/main merges and legacy imports", nestedBranchesMergeAndValidate),
            ("parent deletion preserves surviving children", deletingParentPreservesChildren),
            ("route ordering persistence and relationship preservation", routeOrderPersistsWithoutChangingRelationships),
            ("unified search and project scoping", unifiedSearchIncludesAllEntities),
            ("relative reminders follow dates and monthly occurrences", relativeRemindersTrackReschedulesAndRecurrences),
            ("reminder DST and horizon boundaries", reminderDaylightSavingAndHorizonBoundaries),
            ("agenda shared work, undated tasks and overnight recurrence", agendaCoversSharedUndatedAndOvernightWork),
            ("legacy workflow fields and relative reminder backup", legacyWorkflowFieldsAndNewRulesRoundTrip),
            ("meeting display includes time, cross-day date and zone", meetingTimeTextPreservesDatesAndZone),
            ("trash restores deletion without overwriting later edits", trashRestoresSingleDeletionAndPreservesLaterEdits),
            ("trash shared relationships and conflict safety", trashSharedProjectAndConflictSafety),
            ("trash disk persistence and legacy migration", trashPersistenceAndLegacyMigration),
            ("single recurring edit and reminder exclusion", recurringSingleEditAndReminders),
            ("following split preserves month-end and exceptions", recurringFollowingPreservesMonthEndAndExceptions),
            ("recurring deletion scopes and recovery", recurringDeletionScopesAndRecovery),
            ("whole series exception remapping across DST", recurringWholeEditRemapsExceptionsAcrossDST),
            ("trash dependency restore order and duplicate protection", trashMultipleDeletionsRestoreInDependencyOrder),
            ("moved exceptions, imported ordering and stopping recurrence", recurringMovedExceptionsAndStoppingSeries),
            ("recording context never guesses first destination", recordingContextNeverGuessesFirstDestination),
            ("recording context follows records and merge source", recordingContextFollowsSelectedRecordAndMerge),
            ("archived/deleted recent locations require explicit choice", archivedAndDeletedLocationsCannotBecomeImplicitDefaults),
            ("choosing location preserves content, dates and settings", choosingLocationPreservesContentDatesAndSettings),
            ("current reminder detail matches queued event", currentReminderDetailMatchesScheduledOccurrence),
            ("month-end legacy and relative reminder pairing", reminderPairingPreservesMonthEndLegacyAndRelativeRules),
            ("DST and split-anchor reminder pairing", reminderPairingHandlesDSTAndSplitAnchors),
            ("notification payload and exact series date", notificationPayloadRoundTripResolvesExactSeriesDate),
            ("stale notifications and meeting exceptions", staleNotificationsRespectExceptionsDeletionAndRescheduling),
            ("notification precision and non-meeting targets", notificationDatesSurviveStoragePrecisionAndNonMeetingTargets),
            ("today reason tags match inclusion predicates", todayAgendaReasonsComeFromTheInclusionConditions),
            ("quick completion preserves dependency validation", quickCompletionKeepsDependencyValidation),
            ("quick undo respects subsequent changes", quickUndoPreservesLaterWorkAndRejectsChangedTask),
            ("quick deadline changes only deadline", quickDeadlineChangesOnlyDeadlineFields),
            ("quick deadline retains local time", quickDeadlineRetainsLocalTimeAcrossZones),
            ("quick deadline handles DST gap", quickDeadlineHandlesDSTGapOnChosenDay),
            ("browsing history restores context and occurrence", browseHistoryRestoresContextAndOccurrence),
            ("browsing history skips invalid and bounds visits", browseHistorySkipsMissingEntriesAndStaysBounded),
            ("day order tolerates time zone changes", dayOrderToleratesTimeZoneChanges),
            ("trash 30-day retention and permanent delete", trashRetentionAndPermanentDelete),
            ("trash restore survives save and reopen", trashRestoreSurvivesReopen),
            ("automation rejects conflicting location", automationRejectsConflictingLocation),
            ("automation batch completion order independent", automationBatchCompletionOrderIndependent),
            ("automation date-only due keeps its day", automationDateOnlyDueKeepsDay),
            ("recurring catch-up adds only latest missed", recurringCatchUpAddsOnlyLatestMissed),
            ("occurrences ignore system calendar kind", occurrencesIgnoreSystemCalendarKind)
        ]
        let filter = ProcessInfo.processInfo.environment["BRANCHLINE_CHECK_FILTER"]
        let selected = cases.filter { filter == nil || $0.0.range(of: filter!, options: .regularExpression) != nil }
        var failed = 0
        for (name, check) in selected {
            do { try check(); print("PASS: \(name)") }
            catch { failed += 1; print("FAIL: \(name): \(error)") }
        }
        print("\(selected.count - failed)/\(selected.count) checks passed")
        if failed > 0 { exit(1) }
        if let directory = ProcessInfo.processInfo.environment["BRANCHLINE_QA_DATA_DIR"] {
            do { try prepareNewFeatureFixture(at: directory); print("QA fixture ready") } catch { print("Fixture failed: \(error)"); exit(1) }
        }
    }
}
