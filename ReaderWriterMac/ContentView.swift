//
//  ContentView.swift
//  ReaderWriterMac
//
//  Created by David M Reed
//

import SwiftUI

@Observable
@MainActor
final class CellModel: Identifiable {
    typealias ID = Int
    typealias Value = Int
    let id: ID
    var valueRead: Value?
    var readTimeStamp: Date?
    var valueToWrite: Value
    var valueWritten: Value?
    var writeTimeStamp: Date?
    var disabled: Bool {
        systemViewModel?.disabledIDs.contains(id) ?? false
    }

    weak var systemViewModel: RWSystemViewModel? = nil

    init(
        id: ID,
        valueToWrite: Value,
        viewModelDelegate: RWSystemViewModel?
    ) {
        self.id = id
        self.valueToWrite = valueToWrite
        self.systemViewModel = viewModelDelegate
    }

    func readButtonTapped() {
        valueRead = nil
        readTimeStamp = nil
        Task { [id, weak self] in
            do {
                let value = try await self?.systemViewModel?.read(id: id)
                guard let self else { return }
                self.readTimeStamp = Date.now
                self.valueRead = value
            } catch {}
        }
    }

    func writeButtonTapped(value: Value? = nil) {
        valueWritten = nil
        writeTimeStamp = nil
        if let value {
            valueToWrite = value
        }
        Task { [id, valueToWrite, weak self] in
            do {
                try await self?.systemViewModel?.write(
                    id: id, value: valueToWrite)
                guard let self else { return }
                self.writeTimeStamp = Date.now
                self.valueWritten = valueToWrite
            } catch {}
        }
    }

    func updateButtonTapped(value: Value? = nil) {
        valueWritten = nil
        writeTimeStamp = nil
        if let value {
            valueToWrite = value
        }
        Task { [id, valueToWrite, weak self] in
            do {
                let value = try await self?.systemViewModel?
                    .update(id: id, value: valueToWrite) {
                        $0 + 1
                    }
                guard let self else { return }
                self.writeTimeStamp = Date.now
                self.valueWritten = value
            } catch {}
        }
    }
}

struct CellView: View {
    @Bindable var model: CellModel

    var body: some View {
        HStack(spacing: 20) {
            Text("\(model.id)")

            Button("Read") {
                model.readButtonTapped()
            }
            .disabled(model.disabled)

            Text(model.valueRead == nil ? "nil" : "\(model.valueRead!)")

            Divider()
                .frame(maxHeight: 50)

            Stepper(value: $model.valueToWrite, in: 0...20) {
                Text("\(model.valueToWrite)")
            }
            .fixedSize()

            Button("Write") {
                model.valueWritten = nil
                model.writeButtonTapped()
            }
            .disabled(model.disabled)

            Button("Update") {
                model.valueWritten = nil
                model.updateButtonTapped()
            }
            .disabled(model.disabled)

            Text(model.valueWritten == nil ? "nil" : "\(model.valueWritten!)")
        }
        // need as workaround when multiple buttons in a Stack
        .buttonStyle(BorderlessButtonStyle())
        .padding(8)
    }
}

@Observable
@MainActor
final class RWSystemViewModel: UIUpdater {
    typealias ID = Int
    typealias Value = Int

    fileprivate var randomlyComplete: Bool
    fileprivate var timerInterval: Double
    fileprivate var completionProbability: Double

    fileprivate var snapshot: ReaderWriterSystem<Int, Int>.Snapshot?
    fileprivate var system: ReaderWriterSystem<Int, Int>
    fileprivate var logMessages = ""

    fileprivate var cellModels: [CellModel]
    fileprivate var disabledIDs: Set<Int> = []

    private var timer: Timer?
    private let numIDs: Int

    init(
        queue: [ReadWrite<Int, Int>],
        numIDs: Int = 10,
        randomlyComplete: Bool = false,
        completionProbability: Double = 0.33,
        timerInterval: Double = 0.75
    ) {
        self.numIDs = numIDs
        self.randomlyComplete = randomlyComplete
        self.completionProbability = completionProbability
        self.timerInterval = timerInterval

        cellModels = []
        system = ReaderWriterSystem(value: 0)
        disabledIDs = []

        cellModels = Array(0..<numIDs)
            .map {
                CellModel(id: $0, valueToWrite: $0, viewModelDelegate: self)
            }
        Task {
            // set the UI update delegate
            await system.setUI(ui: self)
            await populateWithQueue(queue: queue)
            let initialSnapshot = await system.snapshot()
            update(snapshot: initialSnapshot)
        }
    }

    func read(id: ID) async throws -> Value {
        disabledIDs.insert(id)
        do {
            let value = try await system.read(id: id)
            disabledIDs.remove(id)
            return value
        } catch {
            disabledIDs.remove(id)
            let message = "error \(error) reading for \(id)"
            log(message)
            throw error
        }
    }

    func write(id: ID, value: Value) async throws {
        disabledIDs.insert(id)
        do {
            try await system.write(id: id, value: value)
            disabledIDs.remove(id)
        } catch {
            disabledIDs.remove(id)
            let message = "error \(error) writing \(value) for \(id)"
            log(message)
            throw error
        }
    }

    func update(id: ID, value: Value, f: (Value) -> Value)
    async throws -> Value
    {
        disabledIDs.insert(id)
        do {
            let value = try await system.update(id: id, update: f)
            disabledIDs.remove(id)
            return value
        } catch {
            disabledIDs.remove(id)
            let message = "error: \(error) updating \(value) for \(id)"
            log(message)
            throw error
        }
    }

    fileprivate func _log(_ message: String) {
        logMessages += message + "\n"
    }

    nonisolated func log(_ message: String) {
        Task {
            await _log(message)
        }
    }

    nonisolated func update(snapshot: ReaderWriterSystem<ID, Value>.Snapshot) {
        Task { @MainActor in
            self.snapshot = snapshot
            disabledIDs = snapshot.activeOrQueuedIDs
        }
    }

    func useRandomChanged() {
        if randomlyComplete {
            startTimer()
        } else {
            stopTimer()
        }
    }

    func clearLogs() {
        logMessages = ""
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer
            .scheduledTimer(withTimeInterval: timerInterval, repeats: true) {
                [weak self] timer in
                Task {
                    await self?.timerTicked()
                }
            }
    }

    private func stopTimer() {
        timer?.invalidate()
    }

    private func timerTicked() {
        if Double.random(in: 0..<1.0) < completionProbability {
            Task {
                await system.completeRandomRW()
            }
        }
    }

    func completeAll() {
        Task {
            await system.completeAll()
        }
    }

    func clearSystem() {
        Task {
            await system.clearSystem()
            let delegate = self
            cellModels = Array(0..<numIDs)
                .map {
                    CellModel(
                        id: $0, valueToWrite: $0, viewModelDelegate: delegate)
                }
            await self.disabledIDs = system.disabledIDs()
        }
    }

    func populateWithQueue(queue: [ReadWrite<Int, Int>]) async {
        if !queue.isEmpty {
            // use detached as it is more likely to put each item in the queue
            // in order since this will run this on a separate thread and
            // call the cellModel methods that are on main thread
            await Task.detached { [cellModels] in
                for rw in queue {
                    switch rw {
                    case .read(let id):
                        await cellModels[id].readButtonTapped()
                    case .write(let id, let value):
                        await cellModels[id].writeButtonTapped(value: value)
                    case .update(let id):
                        await cellModels[id].updateButtonTapped()
                    }
                    // wait to give main thread time to start each task
                    // befor inserting next one
                    try? await Task.sleep(for: .milliseconds(10))
                }
            }.value
        }
    }
}

struct ContentView: View {
    @Bindable var model: RWSystemViewModel

    var body: some View {
        VStack {
            statusViews()

            HStack {
                List {
                    ForEach(model.cellModels) { cellModel in
                        CellView(model: cellModel)
                    }
                }
                .frame(maxWidth: 450)
                ScrollView {
                    TextEditor(text: $model.logMessages)
                        .font(.body.monospacedDigit())
                        .lineSpacing(5)
                        .disabled(true)
                        .frame(minWidth: 200, minHeight: 500)
                }
            }
        }
        .padding()
        .frame(minWidth: 800, minHeight: 700)
    }

    func statusViews() -> some View {
        VStack(alignment: .leading) {
            HStack {
                Text("Value: ")
                if let snapshot = model.snapshot {
                    Text("\(snapshot.value)")
                }
                Spacer()
                Toggle(isOn: $model.randomlyComplete) {
                    Text("Randomly Complete")
                }
                .onChange(of: model.randomlyComplete, initial: true) {
                    model.useRandomChanged()
                }
                Spacer()

                Button("Clear Logs") {
                    model.clearLogs()
                }
                .padding(.trailing, 32)
                Button("Clear System") {
                    model.clearSystem()
                }
            }

            HStack {
                Text("Active")
                    .padding(.leading)
                if let snapshot = model.snapshot {
                    snapshot.activeSetButtons(system: model.system)
                        .frame(alignment: .leading)
                }
                Spacer()
                Button("Complete all") {
                    model.completeAll()
                }
                .padding(.trailing)
            }
            .disabled(model.randomlyComplete)
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.primary, lineWidth: 2)
            )

            HStack {
                Text("Waiting")
                    .padding(.leading)
                    .frame(alignment: .leading)
                if let snapshot = model.snapshot {
                    snapshot.queueView()
                        .frame(alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.primary, lineWidth: 2)
            )
        }
    }
}

#Preview {
    @Previewable @State var model = RWSystemViewModel(
        queue: [
            .write(id: 0, value: 10),
            .read(id: 1),
            .update(id: 2),
            .read(id: 3),
            .write(id: 4, value: 4),
            .read(id: 5),
            .read(id: 6),
            .write(id: 7, value: 7),
            .read(id: 8),
        ],
        randomlyComplete: true
    )

    ContentView(model: model)
}
