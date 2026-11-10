import Foundation
import Testing
@testable import SyncCore

@Suite("Settings support")
struct SettingsSupportTests {
    private func mapping(_ change: (inout ListMapping) -> Void = { _ in }) -> ListMapping {
        var m = ListMapping(id: "1", listTitle: "Home", targetTitle: "Home")
        change(&m)
        return m
    }

    @Test func anOverrideChoiceMapsToNilTrueAndFalseAndBack() {
        #expect(OverrideChoice.global.value == nil)
        #expect(OverrideChoice.on.value == true)
        #expect(OverrideChoice.off.value == false)
        for value in [nil, true, false] as [Bool?] { #expect(OverrideChoice(value).value == value) }
    }

    @Test func aDefaultMappingHasNoCustomPreferences() {
        #expect(!mapping().hasCustomPreferences)
        // Controls that sit on the row itself, and values the engine ignores, do not light the indicator.
        #expect(!mapping { $0.paused = true; $0.syncSections = false }.hasCustomPreferences)
        #expect(!mapping { $0.alwaysTag = "  " }.hasCustomPreferences)
        #expect(!mapping { $0.eveningFromHour = 24 }.hasCustomPreferences)
        #expect(!mapping { $0.sectionsAsProjects = true }.hasCustomPreferences)   // project mode ignores it
    }

    @Test func eachNonDefaultPreferenceCountsAsCustom() {
        let changes: [(inout ListMapping) -> Void] = [
            { $0.direction = .remindersToThings }, { $0.propagateDeletes = true }, { $0.undatedArriveAs = .someday },
            { $0.alwaysTag = "Home" }, { $0.includeCompletedOnFirstLink = false }, { $0.syncChecklists = false },
            { $0.dueMapsTo = .deadline }, { $0.eveningFromHour = 0 }, { $0.canceledBecomes = .deleted },
            { $0.syncSomeday = false }, { $0.assigneeTags = ["me": "Mine"] },
            { $0.mode = .area; $0.sectionsAsProjects = true },
        ]
        for change in changes { #expect(mapping(change).hasCustomPreferences) }
    }

    @Test func preferencesAModeOrDirectionIgnoresGiveAReason() {
        let twoWay = mapping()
        for preference in ListPreference.allCases where preference != .sectionsAsProjects {
            #expect(twoWay.reasonIgnored(preference, deletesPropagate: true) == nil)
        }
        #expect(twoWay.reasonIgnored(.sectionsAsProjects, deletesPropagate: true) != nil)
        #expect(mapping { $0.mode = .area }.reasonIgnored(.sectionsAsProjects, deletesPropagate: true) == nil)

        let fromThings = mapping { $0.direction = .thingsToReminders }
        #expect(fromThings.reasonIgnored(.alwaysTag, deletesPropagate: true) != nil)
        #expect(fromThings.reasonIgnored(.undatedArriveAs, deletesPropagate: true) != nil)
        #expect(fromThings.reasonIgnored(.eveningFromHour, deletesPropagate: true) != nil)
        #expect(fromThings.reasonIgnored(.assigneeTags, deletesPropagate: true) == nil)

        let fromReminders = mapping { $0.direction = .remindersToThings }
        #expect(fromReminders.reasonIgnored(.assigneeTags, deletesPropagate: true) != nil)
        #expect(fromReminders.reasonIgnored(.canceledBecomes, deletesPropagate: true) != nil)
        #expect(fromReminders.reasonIgnored(.alwaysTag, deletesPropagate: true) == nil)

        #expect(mapping { $0.dueMapsTo = .deadline }.reasonIgnored(.eveningFromHour, deletesPropagate: true) != nil)
    }

    @Test func deletingACanceledItemsReminderNeedsDeletesForTheList() {
        #expect(mapping().reasonIgnored(.canceledBecomes, deletesPropagate: false) != nil)
        #expect(mapping { $0.propagateDeletes = true }.reasonIgnored(.canceledBecomes, deletesPropagate: false) == nil)
        #expect(mapping { $0.propagateDeletes = false }.reasonIgnored(.canceledBecomes, deletesPropagate: true) != nil)
    }

    @Test func thePriorityTagClashesOnlyWhenItNamesTheFlagTag() {
        #expect(!SyncConfig().priorityTagClashesWithFlag)
        #expect(SyncConfig(priorityTag: " Important ").priorityTagClashesWithFlag)
        #expect(!SyncConfig(priorityTag: "Urgent").priorityTagClashesWithFlag)
        #expect(!SyncConfig(flaggedTagTitle: "", priorityTag: " ").priorityTagClashesWithFlag)
        #expect(SyncConfig(flaggedTagTitle: " ").effectiveFlaggedTag == nil)
    }

    @Test func aTagMenuListsExistingTagsOnceAndKeepsAMissingSavedTitle() {
        let menu = TagMenu(known: ["work", "Errands", "work", ""], current: "Errands")
        #expect(menu.titles == ["Errands", "work"])
        #expect(menu.missing == nil)
        #expect(TagMenu(known: ["Errands"], current: "Gone").missing == "Gone")
        #expect(TagMenu(known: ["Errands"], current: "errands").missing == "errands")   // the flag tag matches exactly
        #expect(TagMenu(known: ["Errands"], current: " ").missing == nil)
        #expect(TagMenu(known: ["Errands"], current: nil).missing == nil)
    }

    @Test func assigneeRowsComeInSortedKeyOrderAndRoundTrip() {
        let saved = ["me": "Mine", "ana@example.com": "Ana", "B7": "Ben"]
        let rows = AssigneeTagRow.rows(from: saved)
        #expect(rows.map(\.sharee) == ["B7", "ana@example.com", "me"])
        #expect(AssigneeTagRow.assigneeTags(from: rows) == saved)
    }

    @Test func incompleteAndRepeatedAssigneeRowsAreLeftOut() {
        let rows = [AssigneeTagRow(sharee: " me ", tag: "Mine"), AssigneeTagRow(sharee: "me", tag: "Other"),
                    AssigneeTagRow(sharee: "", tag: "Ana"), AssigneeTagRow(sharee: "ana@example.com", tag: "")]
        #expect(AssigneeTagRow.assigneeTags(from: rows) == ["me": "Mine"])
    }
}
