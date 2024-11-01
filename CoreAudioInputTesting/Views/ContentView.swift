//
//  ContentView.swift
//  CoreAudioInputTesting
//
//  Created by Johnny Turpin on 11/1/24.
//

import SwiftUI

struct ContentView: View {
	
	@EnvironmentObject private var appModel: AppViewModel
	
    var body: some View {
		VStack {
			HStack {
				Picker("Input Device: ", selection: $appModel.currentInputDeviceId) {
					Text("None").tag(nil as UInt32?)
					ForEach(appModel.inputAudioDevices, id: \.self.id) {
						device in
						
						Text(device.displayableName ?? "N/A").tag(device.id as UInt32?)
					}
				}
				.frame(maxWidth: 300)
				Spacer()
				Button {
					if appModel.player.isRunning == true {
						appModel.stopAUGraph()
					} else {
						appModel.startAUGraph()
					}
				} label: {
					Text(appModel.isPlaying == true ? "Stop AU" : "Start AU")
				}
				Spacer()
				Picker("Output Device: ", selection: $appModel.currentOutputDeviceId) {
					Text("None").tag(nil as UInt32?)
					ForEach(appModel.outputAudioDevices, id: \.self.id) {
						device in
						Text(device.displayableName ?? "N/A").tag(device.id as UInt32?)
					}
				}
				.frame(maxWidth: 300)
				
			}
			Divider()
			List {
				if let currentDevice = appModel.currentInputDevice {
					ForEach(0..<currentDevice.numChannels, id: \.self) {
						chan in
						VStack {
							HStack {
								Text("Channel[\(chan.description)]")
									.frame(width: 75)
								HStack {
									ForEach(0..<20) {
										level in
										Rectangle()
											//.fill(level < 12 ? .green : level < 18 ? .yellow: .red)
											.stroke(.white.opacity(0.1), lineWidth: 1)
											.frame(width: 10)
									}
								}
							}
						}
						
					}
				}

			}
			.listStyle(.sidebar)
			Spacer()
		}
		.padding()
		.frame(minWidth: 800, minHeight: 800)
		.onAppear {
			appModel.populateAudioDevices()
		}
    }
}

#Preview {
    ContentView()
}
