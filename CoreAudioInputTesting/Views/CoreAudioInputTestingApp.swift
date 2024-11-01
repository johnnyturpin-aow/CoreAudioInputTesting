//
//  CoreAudioInputTestingApp.swift
//  CoreAudioInputTesting
//
//  Created by Johnny Turpin on 11/1/24.
//

import SwiftUI

@main
struct CoreAudioInputTestingApp: App {
	
	@StateObject private var appModel = AppViewModel()
	
    var body: some Scene {
        WindowGroup {
            ContentView()
				.environmentObject(appModel)
				.preferredColorScheme(.dark)
				.frame(minWidth: 800, minHeight: 800)
        }
		.windowToolbarStyle(UnifiedCompactWindowToolbarStyle())
    }
}
