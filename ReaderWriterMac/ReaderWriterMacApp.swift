//
//  ReaderWriterMacApp.swift
//  ReaderWriterMac
//
//  Created by David M Reed
//

import SwiftUI

@main
struct ReaderWriterMacApp: App {
    @State var model = RWSystemViewModel(
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
        randomlyComplete: false
    )

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
    }
}
