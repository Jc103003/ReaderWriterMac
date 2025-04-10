//
//  ReadWrite.swift
//  ReaderWriterMac
//
//  Created by David M Reed
//

public typealias ReadWriteID = CustomStringConvertible & Hashable & Comparable
    & Sendable

public typealias ReadWriteValue = CustomStringConvertible & Hashable & Sendable

/// enum for indicating the type of operation to perform
public enum ReadWrite<ID: ReadWriteID, Value: ReadWriteValue>: Hashable,
    Sendable
{
    // read by the specified ID
    case read(id: ID)
    // write of value by the specified ID
    case write(id: ID, value: Value)
    // update by the specified ID
    case update(id: ID)
}

extension ReadWrite: Identifiable {
    /// use the id to conform to Identifiable
    public var id: ID {
        switch self {
        case .read(let id):
            return id
        case .write(let id, _):
            return id
        case .update(let id):
            return id
        }
    }
}

extension ReadWrite: CustomStringConvertible {
    /// convert to String using R for read, U for update, or W folllowed by new value for write
    public var description: String {
        switch self {
        case .read(let id):
            "\(id)R"
        case .write(let id, let value):
            "\(id)W: \(value)"
        case .update(let id):
            "\(id)U"
        }
    }
}

extension ReadWrite: Comparable {
    /// comapre based on ID so we can sort the active readers by ID
    /// - Parameters:
    ///   - lhs: lhs ReadWrite
    ///   - rhs: rhs ReadWrite
    /// - Returns: lhs.id < rhs.id
    public static func < (lhs: ReadWrite<ID, Value>, rhs: ReadWrite<ID, Value>)
        -> Bool
    {
        lhs.id < rhs.id
    }
}

@available(iOS 17, macOS 14, *)
extension ReadWrite {
    func finishOperation(system: ReaderWriterSystem<ID, Value>) {
        switch self {
        case .read(let id):
            Task {
                await system.readFinished(id: id)
            }

        case .write(let id, _), .update(let id):
            Task {
                await system.writeOrUpdateFinished(id: id)
            }
        }
    }
}

#if os(iOS) || os(macOS)
    import SwiftUI
    @available(iOS 17, macOS 14, *)
    @MainActor
    extension ReadWrite {
        /// SwiftUI Text  using the ReadWrite CustomStringConvertible
        /// - Returns: SwiftUI Text for displaying ReadWrite
        func text() -> some View {
            switch self {
            case .read(_):
                Text("\(self)")
                    .padding(8)
                    .background(.green.opacity(0.5))
            case .write(_, _):
                Text("\(self)")
                    .padding(8)
                    .background(.red.opacity(0.5))
            case .update(_):
                Text("\(self)")
                    .padding(8)
                    .background(.blue.opacity(0.5))
            }
        }

        /// SwiftUI Button using the ReadWrite CustomStringConvertible
        /// - Parameters:
        ///   - active: true if button should be active
        ///   - action: () -> Void action to execute when Button pressed)
        /// - Returns: SwiftUI Button for displaying ReadWrite
        func button(active: Bool, action: @escaping () -> Void) -> some View {
            Button {
                action()
            } label: {
                text()
            }
            .buttonStyle(.plain)
            .disabled(!active)
        }
    }
#endif
