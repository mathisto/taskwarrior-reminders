//
//  Reminders.swift
//  taskwarrior-reminders
//
//  Created by Bryce Lampe on 12/29/19.
//

import EventKit
import Foundation
import Models

public class RemindersRepository {
    private var store: EKEventStore

    public init(_ e: EKEventStore) {
        self.store = e
        self.assertAuthorized()
    }

    public func fetchReminderTask(_ reminderID: String?, commit: Bool = false) -> Task {
        return reminderToTask(fetchOrCreateExistingReminder(reminderID, commit: commit))
    }

    // TODO leaky
    public func fetchAllReminders() -> [EKReminder] {
        // Need to ensure we don't fetch stale date, but a refresh would cause
        // more notifications... so reset.
        self.store.reset()
        var fetchedReminders: [EKReminder] = []
        let semaphore = DispatchSemaphore.init(value: 0)
        self.store.fetchReminders(
            matching: self.store.predicateForReminders(in: nil),
            completion: { reminders in
                fetchedReminders = reminders ?? []
                semaphore.signal()
            }
        )
        semaphore.wait()
        return fetchedReminders
    }

    private func fetchOrCreateExistingReminder(
        _ reminderID: String?,
        commit: Bool=false
    ) -> EKReminder {
        if reminderID != nil {
            if let existing = self.store.calendarItem(withIdentifier: reminderID!) as! EKReminder? {
                return existing
            }
        }
        let reminder = EKReminder(eventStore: self.store)
        let defaultCalendar = self.store.defaultCalendarForNewReminders()!
        reminder.calendar = defaultCalendar
        try! self.store.save(reminder, commit: commit)
        return reminder
    }

    public func assertAuthorized() {
        let semaphore = DispatchSemaphore.init(value: 0)
        store.requestAccess(to: .reminder, completion: {
            (success, _) -> Void in
            if !success {
                print("Please give Reminders permission!")
                exit(64)
            }
            semaphore.signal()
        })
        semaphore.wait()
    }

    public func upsertToReminders(task: Task) -> SyncResult {
        let existing = fetchReminderTask(task.reminderID, commit: true)

        let syncResult = synchronize(
            updatesFrom: task,
            toOlder: existing
        )

        if !syncResult.madeChanges && !syncResult.task.isDeleted() {
            return syncResult
        }

        let reminder = taskToReminder(syncResult.task)

        if syncResult.madeChanges {
            try! self.store.save(reminder, commit: true)
        }

        if syncResult.task.isDeleted() {
            try! self.store.remove(reminder, commit: true)
        }

        return syncResult
    }

    private func ensureCalendar(name: String?) -> EKCalendar {
        let defaultCalendar = self.store.defaultCalendarForNewReminders()!
        guard name != nil else {
            return defaultCalendar
        }
        let calendars = self.store.calendars(for: .reminder)

        if let calendar = calendars.filter({$0.title == name}).first {
            return calendar
        }

        let calendar = EKCalendar.init(for: .reminder, eventStore: self.store)
        calendar.title = name!
        calendar.source = defaultCalendar.source
        try! self.store.saveCalendar(calendar, commit: true)
        return calendar
    }

    private func reminderToTask(_ r: EKReminder) -> Task {
        let t = Task()
        t.title = r.title
        t.status = fromReminderStatus(r.isCompleted)
        t.priority = fromReminderPriority(UInt(r.priority))
        t.project = r.calendar!.title
        t.reminderID = r.calendarItemIdentifier
        t.lastModified = r.lastModifiedDate
        t.due = getDueDate(r)
        t.notes = fromReminderNotes(r.notes ?? "")
        return t
    }

    private func taskToReminder(_ t: Task, commit: Bool = false) -> EKReminder {
        let reminder = fetchOrCreateExistingReminder(t.reminderID, commit: commit)
        reminder.title = t.title
        reminder.isCompleted = t.isCompleted()
        reminder.priority = Int(toReminderPriority(t.priority).rawValue)
        reminder.calendar = ensureCalendar(name: t.project)
        setDueDate(reminder, t.due)
        reminder.notes = toReminderNotes(t.notes)
        return reminder
    }

    private func toReminderStatus(_ s: Status) -> Bool {
        return s == Status.completed
    }

    private func fromReminderStatus(_ isCompleted: Bool) -> Status {
        switch isCompleted {
        case true:
            return Status.completed
        default:
            return Status.unknown
        }
    }

    private func fromReminderPriority(_ p: UInt) -> Priority {
        switch p {
        case EKReminderPriority.high.rawValue:
            return Priority.high
        case EKReminderPriority.medium.rawValue:
            return Priority.medium
        case EKReminderPriority.low.rawValue:
            return Priority.low
        default:
            return Priority.none
        }
    }

    private func toReminderPriority(_ p: Priority) -> EKReminderPriority {
        switch p {
        case Priority.high:
            return EKReminderPriority.high
        case Priority.medium:
            return EKReminderPriority.medium
        case Priority.low:
            return EKReminderPriority.low
        default:
            return EKReminderPriority.none
        }
    }

    private func toReminderNotes(_ annotations: [Annotation]) -> String {
        if annotations == [] {
            return ""
        }

        var notes: [String] = []

        for annotation in annotations {
            notes += [annotation.description]
        }

        return notes.joined(separator: "\n\n")
    }

    private func fromReminderNotes(_ notes: String) -> [Annotation] {
        if notes == "" {
            return []
        }
        var annotations: [Annotation] = []

        let chunks = notes.components(separatedBy: "\n\n")
        for chunk in chunks {
            var a = Annotation.init()
            a.description = chunk
            annotations += [a]
        }
        return annotations
    }

    private func getDueDate(_ r: EKReminder) -> Date? {
        if r.dueDateComponents == nil {
            return nil
        }

        let date = Calendar.current.date(from: r.dueDateComponents!)

        let alarm = r.alarms?.filter({ alarm in
            alarm.type == .display }).first

        if alarm != nil {
            return date! + alarm!.relativeOffset
        }

        return date
    }

    private func setDueDate(_ r: EKReminder, _ d: Date?) {
        guard d != nil else {
            return
        }

        var components = Calendar.current.dateComponents(
            in: TimeZone.current, from: d!)

        // Bump start of day notifications to early morning
        if components.hour == 0 && components.minute == 0 && components.second == 0 {
            components.hour = 6
        }
        r.dueDateComponents = components
        r.addAlarm(EKAlarm.init(relativeOffset: 0))
    }
}
