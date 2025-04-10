//
//  ReaderWriterSystem.swift
//  ReaderWriterMac
//
//  Created by David M Reed
//

import Foundation

#if canImport(OSLog)
    import OSLog

    @available(iOS 17, macOS 14, *)
    extension Logger {
        private static let subsystem = "com.dave256apps.RWMac"
        static let status = Logger(subsystem: subsystem, category: "status")
    }
#endif

#if canImport(SwiftUI)
    import SwiftUI
#endif

@available(iOS 17, macOS 14, *)
public protocol UIUpdater<ID, Value>: AnyObject {
    associatedtype ID: ReadWriteID
    associatedtype Value: ReadWriteValue

    /// deletgate method to update UI with snapshot of ReadWRiteSystem
    /// - Parameter snapshot: snapshot to send to the UI
    func update(snapshot: ReaderWriterSystem<ID, Value>.Snapshot)

    /// delegate method for logging information
    /// - Parameter message: message to log
    func log(_ message: String)
}

@available(iOS 17, macOS 14, *)
public actor ReaderWriterSystem<ID: ReadWriteID, Value: ReadWriteValue> {

    /// snapshot of the system to send to UI for displaying
    public struct Snapshot: Sendable {
        let value: Value
        let activeSet: Set<ReadWrite<ID, Value>>
        let queue: [ReadWrite<ID, Value>]

        /// create the snapshot
        /// - Parameters:
        ///   - value: current value
        ///   - activeSet: current active readers or active write/update
        ///   - queue: current read/write/update in the queue
        init(
            value: Value,
            activeSet: Set<ReadWrite<ID, Value>>,
            queue: [ReadWrite<ID, Value>]
        ) {
            self.value = value
            self.activeSet = activeSet
            self.queue = queue
        }

        /// the ID values of the active read/write/update operations
        var activeIDs: Set<ID> {
            Set(activeSet.map { $0.id })
        }

        /// the ID values of the queued read/write/update operations
        var queuedIDs: Set<ID> {
            Set(queue.map { $0.id })
        }

        /// the ID values of the actived or queued read/write/update operations
        var activeOrQueuedIDs: Set<ID> {
            activeIDs.union(queuedIDs)
        }

        #if canImport(SwiftUI)
            /// view with SwiftUI Button for each active read/write/update
            /// - Parameter system: system it is in so can call finishOperation
            /// - Returns: HStack with the Button for each item in activeSet
            @available(iOS 17, macOS 14, *)
            @MainActor
            @ViewBuilder func activeSetButtons(system: ReaderWriterSystem)
                -> some View
            {
                let items = activeSet.sorted()
                HStack {
                    ForEach(items) { rw in
                        rw.button(active: true) {
                            rw.finishOperation(system: system)
                        }
                    }
                }
            }

            /// View showing Text for each item in the queue
            /// - Returns: HStack with Text for each item in queue
            @available(iOS 17, macOS 14, *)
            @MainActor
            @ViewBuilder func queueView() -> some View {
                HStack {
                    ForEach(queue) { rw in
                        rw.text()
                    }
                }
            }
        #endif
    }

    public var value: Value
    public var ui: (any UIUpdater<ID, Value>)?

    public init(value: Value, ui: (any UIUpdater<ID, Value>)? = nil) {
        self.value = value
        self.ui = ui
    }

    deinit {
        for (id, continuation) in readRequestContinuations {
            readRequestContinuations.removeValue(forKey: id)
            continuation.resume(throwing: CancellationError())
        }
        for (id, continuation) in writeRequestContinuations {
            writeRequestContinuations.removeValue(forKey: id)
            continuation.resume(throwing: CancellationError())
        }
        for (id, continuation) in readFinishContinuations {
            readFinishContinuations.removeValue(forKey: id)
            continuation.resume(throwing: CancellationError())
        }
        for (id, continuation) in writeFinishContinuations {
            writeFinishContinuations.removeValue(forKey: id)
            continuation.resume(throwing: CancellationError())
        }
    }

    /// returns a Snapshot indicating the current value, active readers/writer, and waiting queue
    ///
    /// can be used to update UI or for a test to validate state
    /// - Returns: Snapshot of the current system
    public func snapshot() -> Snapshot {
        Snapshot(value: value, activeSet: activeSet, queue: queue)
    }

    /// sets the UI object to be called with snapshot and logging information and immediately calls
    /// it with the current state; other methods should call it when the activeSet/queue update
    /// - Parameter ui: delegate object
    public func setUI(ui: (any UIUpdater<ID, Value>)) {
        self.ui = ui
        ui.update(snapshot: snapshot())
    }

    /// returns the Set of ReadWrite IDs that are in progress (active or waiting in queue) as
    ///  they should not start new ReadWrite operations until their existing one is complete
    /// - Returns: Set of active/waiting IDs in the system
    public func disabledIDs() -> Set<ID> {
        return Set(activeSet.map { $0.id }).union(queue.map { $0.id })
    }

    /// logs the message for tracking progress of system
    ///
    /// uses Logger (on supported) platforms or print on platforms without Logger
    /// also calls the UIUpdater's (if it is not nil) log method with the message
    ///
    /// - Parameter message: message to log
    private func logMessage(_ message: String) {
        let formatter = Date.FormatStyle(date: .omitted, time: .standard)
            .secondFraction(
                .fractional(3)
            )
        let message = formatter.format(Date.now) + ": " + message
        ui?.log(message)
        #if canImport(OSLog)
            Logger.status.info("\(message)")
        #else
            print(message)
        #endif
    }

    /// sets a ReadWrite operation that is actively reading/writing to complete
    ///
    /// precondition: the rw operation is in the activeSet (i.e., it has gotten past the request phase) and
    /// is actively reading/writing but not yet completed
    ///
    /// postcondition: the ReadWrite operation is set to complete
    ///
    /// - Parameter rw: ReadWrite to be completed
    private func completeRW(_ rw: ReadWrite<ID, Value>) {
        switch rw {
        case .read(let id):
            readFinished(id: id)
        case .write(let id, _), .update(let id):
            writeOrUpdateFinished(id: id)
        }
    }

    /// sets a ReadWrite operation that is actively reading/writing to complete
    ///
    /// precondition: the rw operation is in the activeSet (i.e., it has gotten past the request phase) and
    /// is actively reading/writing but not yet completed
    ///
    /// postcondition: the ReadWrite operation is set to complete
    ///
    /// - Parameter id: ID of the ReadWrite that is to be completed
    /// - Returns: true if a ReadWrite with that ID is found and set to complete or
    ///            false if no ReadWrite with that ID found
    @discardableResult
    func completeID(_ id: ID) -> Bool {
        for rw in activeSet {
            if rw.id == id {
                completeRW(rw)
                return true
            }
        }
        return false
    }

    /// sets a random ReadWrite operation that is actively reading/writing to complete
    ///
    /// postcondition: a random ReadWrite operation is set to complete
    ///
    /// - Returns: true if there was an active ReadWrite to complete or false if no active ReadWrite
    @discardableResult
    func completeRandomRW() -> Bool {
        if let rw = activeSet.randomElement() {
            completeRW(rw)
            return true
        }
        return false
    }

    /// completes all the ReadWrite operations that are actively reading/writing
    ///
    /// postcondition: a random ReadWrite operation is set to complete
    func completeAll() {
        for rw in activeSet {
            completeRW(rw)
        }
    }

    /// performs a read for the specified ID
    ///
    /// if duration is not nil, the read takes that long to complete - use:
    /// `try await`Task.sleep(or: duration)`
    /// otherwise it waits for the `readFinished` method to be called for its id
    ///
    /// precondition: the ID is not curreintly active or in the waiting queue
    ///
    /// postcondition: the read occurs in a FIFO order using the waiting queue and messages are
    /// logged before it waits, as it is reading, and when it finishes reading
    ///
    /// - Parameters:
    ///   - id: ID that wants to read
    ///   - duration: optional duration of time that the read takes to complete
    /// - Returns: the value that was read
    public func read(id: ID, duration: Duration? = nil) async throws -> Value {
        precondition(
            !disabledIDs().contains(id), "ID \(id) is in currently in use")

        logMessage("id: \(id) requesting read")

        // wait for request to be approved
        try await requestRead(id: id)

        // perform the read when we are allowed
        logMessage("id: \(id) start read")
        let value = try await actualRead(id: id, duration: duration)
        logMessage("id: \(id) finished read with \(value)")

        // complete the read by updating activeSet and queue
        completeRead(id: id)
        return value
    }

    /// performs a write for the specified ID
    ///
    /// if duration is not nil, the write takes that long to complete
    /// otherwise it waits for the `writeOrUpdateFinished` method to be called for its id
    ///
    /// precondition: the ID is not curreintly active or in the waiting queue
    ///
    /// postcondition: the read occurs in a FIFO order using the waiting queue and messages are
    /// logged before it waits, as it is writing, and when it finishes writing
    ///
    /// - Parameters:
    ///   - id: ID that wants to write
    ///   - value: value to write
    ///   - duration: optional duration of time that the write takes to complete
    /// - Returns: the value that was written
    @discardableResult
    public func write(id: ID, value: Value, duration: Duration? = nil)
        async throws -> Value
    {
        precondition(
            !disabledIDs().contains(id), "ID \(id) is in currently in use")

        logMessage("id: \(id) requesting to write \(value)")
        // wait for request to be approved
        try await requestWriteOrUpdate(id: id, value: value)

        // now we can start writing
        logMessage("id: \(id) starting write of \(value)")
        try await actualWrite(id: id, value: value, duration: duration)
        logMessage("id: \(id) finished write of \(value)")

        // use helper method to complete the write
        completeWriteOrUpdate(id: id, value: value)
        return value
    }

    /// performs am update for the specified ID
    ///
    /// if duration is not nil, the update takes that long to complete
    /// otherwise it waits for the `writeOrUpdateFinished` method to be called for its id
    ///
    /// precondition: the ID is not curreintly active or in the waiting queue
    ///
    /// postcondition: the read occurs in a FIFO order using the waiting queue and messages are
    /// logged before it waits, as it is writing, and when it finishes writing
    ///
    /// - Parameters:
    ///   - id: ID that wants to update
    ///   - update: function/closure to that calculates the updated value
    ///   - duration: optional duration of time that the write takes to complete
    /// - Returns: the updated value that is written
    public func update(
        id: ID,
        update: (Value) -> Value,
        duration: Duration? = nil
    ) async throws -> Value {
        precondition(
            !disabledIDs().contains(id), "ID \(id) is in currently in use")

        logMessage("id: \(id) requesting to update")
        // wait for request to be approved
        try await requestWriteOrUpdate(id: id, value: value, isUpdate: true)

        // now we can start the update
        let oldValue = self.value
        logMessage("id: \(id) starting update of \(value)")
        let newValue = try await actualUpdate(
            id: id, update: update, duration: duration)
        logMessage("id: \(id) finished update from \(oldValue) to \(newValue)")

        // use helper method to complete the write
        completeWriteOrUpdate(id: id, value: value, isUpdate: true)
        return newValue
    }

    // MARK: - student methods to implement

    /// clears the system of any in progress operations (
    ///
    /// postcondition: all active and waiting operations are removed, ui?.update is called, and
    /// all active continuations are resumed by `throwing: CancellationError()`
    ///
    public func clearSystem() {
        #warning("implement this method")
    }

    /// called when an active read is finished reading to indicate it should complete
    /// - Parameter id: id of read to complete
    func readFinished(id: ID) {
#warning("implement this method")

    }

    /// called when an active write/update is finished writing/updating to indicate it should complete
    /// - Parameter id: id of write or update to complete
    func writeOrUpdateFinished(id: ID) {
#warning("implement this method")

    }

    /// request a read operation for the specified id
    ///
    /// does not return until the read is activer (i.e, their turn in queue and no writers active)
    ///
    /// - Parameter id: id that wants to read
    private func requestRead(id: ID) async throws {
#warning("implement this method")

    }

    /// performs a read for the specified ID
    ///
    /// if duration is not nil, the read takes that long to complete - use:
    /// `try await`Task.sleep(or: duration)`
    /// otherwise it waits for the `readFinished` method to be called for its id
    ///
    /// it does not return until either the duration has passed or `readFinished` is called
    ///
    /// - Parameters:
    ///   - id: ID that wants to read
    ///   - duration: optional duration of time that the read takes to complete
    /// - Returns: the value that was read
    private func actualRead(id: ID, duration: Duration?) async throws -> Value {
#warning("implement this method")

    }

    /// complete the read for the specified id
    ///
    /// - Parameter id: id that is completing a read
    private func completeRead(id: ID) {
        activeSet.remove(.read(id: id))
        // now potentially let in next item(s) from queue
        processQueue()
    }

    /// request a write or update operation for the specified id
    ///
    /// does not return until the write/update is active (i.e, their turn in queue and
    /// no other active read/write/update in the system)
    ///
    /// postcondition: write/update is placed in the waiting queue until its turn, and then
    /// moved to adtive set when it can access
    ///
    /// - Parameters:
    ///   - id: id that wants to write/update
    ///   - value: if a write, the value that is being written (value is ignored if an update)
    ///   - isUpdate: true if the request is for an update, false if a write
    private func requestWriteOrUpdate(
        id: ID, value: Value, isUpdate: Bool = false
    )
        async throws
    {
#warning("implement this method")

    }

    /// performs a write for the specified ID
    ///
    /// if duration is not nil, the write takes that long to complete - use:
    /// `try await`Task.sleep(or: duration)`
    /// otherwise it waits for the `writeOrUpdateFinished` method to be called for its id
    ///
    /// it does not return until either the duration has passed or `writeOrUpdateFinished` is called
    ///
    /// - Parameters:
    ///   - id: ID that wants to write
    ///   - value: value it wants to write
    ///   - duration: optional duration of time that the write takes to complete
    /// - Returns: value (which was written)
    @discardableResult
    private func actualWrite(id: ID, value: Value, duration: Duration?)
        async throws -> Value
    {
#warning("implement this method")

    }

    /// performs an update for the specified ID
    ///
    /// if duration is not nil, the update takes that long to complete - use:
    /// `try await`Task.sleep(or: duration)`
    /// otherwise it waits for the `writeOrUpdateFinished` method to be called for its id
    ///
    /// it does not return until either the duration has passed or `writeOrUpdateFinished` is called
    ///
    /// - Parameters:
    ///   - id: ID that wants to write
    ///   - update: function/closure to that calculates the updated value
    ///   - duration: optional duration of time that the write takes to complete
    /// - Returns: the updated value that is written
    private func actualUpdate(
        id: ID, update: (Value) -> Value, duration: Duration? = nil
    ) async throws -> Value {
#warning("implement this method")

    }

    /// complete the write or update for the specified id
    /// - Parameters:
    ///   - id: id of ReadWrite that is being completed
    ///   - value: for a write, the value that was being written (ignored for an update)
    ///   - isUpdate: true if operation was a wite or false if an update
    private func completeWriteOrUpdate(
        id: ID, value: Value, isUpdate: Bool = false
    ) {
#warning("implement this method")

    }

    /// process the waiting queue and let in all the ReadWrite operatons that can be active
    ///
    /// items in the waiting queue are let in using a FIFO order
    /// a read can be let in when there is not an active write/update
    /// a write or update can only be let in when there are active reads or write/update operations
    private func processQueue() {
#warning("implement this method")

        // update UI when done processing queue
        ui?.update(snapshot: snapshot())
    }

    /// whether or not there is a write/update active
    /// might want to make this a compute property that checks if activeSet is not empty and
    /// first iitem (which is only item in that case) is a write or update
    private var isWriting: Bool = false

    /// set of active ReadWrite in system (zero or more readers or just one write/update)
    private var activeSet: Set<ReadWrite<ID, Value>> = []
    private var numActive: Int { activeSet.count }

    /// FIFO queue of ReadWrite objects waiting to enter system
    private var queue: [ReadWrite<ID, Value>] = []

    // store continuations for requesting a read or write by ID
    private var readRequestContinuations:
        [ID: CheckedContinuation<Void, Error>] = [:]
    private var writeRequestContinuations:
        [ID: CheckedContinuation<Void, Error>] = [:]

    // store continuations for finishing a read or write by ID
    private var readFinishContinuations:
        [ID: CheckedContinuation<Void, Error>] = [:]
    private var writeFinishContinuations:
        [ID: CheckedContinuation<Void, Error>] = [:]
}
