//
//  main.swift
//  taskwarrior-reminders
//
//  Created by Bryce Lampe on 12/29/19.
//
import AppKit
import Foundation
import EventKit
import Repositories

private func main(store: EKEventStore) {
    let syncStart = dawnOfTime()
    let reminders = RemindersRepository.init(store)
    let fsobserver = TaskwarriorObserver(reminders, syncSince: syncStart)
    let observer = RemindersObserver(reminders, syncSince: syncStart)

    NotificationCenter.default.addObserver(
        forName: .EKEventStoreChanged,
        object: store,
        queue: nil,
        using: observer.storeChanged)
    print("[task-reminders-sync] We're off to the races!")
}

// Returns the date the binary was compiled on the user's machine, so we don't
// automatically sync any tasks/reminders created before that time.
private func dawnOfTime() -> Date {
    if CommandLine.arguments.contains("--all") {
        return Date.init(timeIntervalSince1970: 0)
    }
    return try! FileManager.default.attributesOfItem(
    atPath: Bundle.main.executablePath!)[FileAttributeKey.modificationDate]
    as? Date ?? Date()
}

private var store = EKEventStore.init()
main(store: store)
RunLoop.main.run()