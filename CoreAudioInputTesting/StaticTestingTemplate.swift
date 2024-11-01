//
//  StaticTestingTemplate.swift
//  AVAudioSessionTesting
//
//  Created by Johnny Turpin on 10/23/24.
//

import SwiftUI

enum TestingAudioInputDevice: String, Identifiable, CaseIterable {
	case device1 = "Internal mac Microphone"
	case device2 = "AudientID 4"
	case device3 = "WebCam"
	case unknown = "Default"
	
	var id: String { return self.rawValue }
	
	var numChannels: Int {
		switch self {
		case .device1:
			return 1
		case .device2:
			return 12
		case .device3:
			return 1
		case .unknown:
			return 1
		}
	}
}

enum TestingAudioOutputDevice: String, Identifiable, CaseIterable {
	case device1 = "Internal mac Speakers"
	case device2 = "AudientID 4"
	case device3 = "Line Output"
	case unknown = "Default"
	
	var id: String { return self.rawValue }
	
	var numChannels: Int {
		switch self {
		case .device1:
			return 2
		case .device2:
			return 6
		case .device3:
			return 2
		case .unknown:
			return 2
		}
	}
}

struct StaticTestingTemplate: View {
	
	@State private var currentInputDevice: TestingAudioInputDevice = .device2
	@State private var currentOutputDevice: TestingAudioOutputDevice?
	
    var body: some View {
		VStack {
			HStack {
				Picker("Input Device: ", selection: $currentInputDevice) {
					ForEach(TestingAudioInputDevice.allCases, id: \.self) {
						device in
						Text(device.rawValue)
					}
				}
				.frame(maxWidth: 250)
				Spacer()
				Button {
					
				} label: {
					Text("Start Audio")
				}
				Spacer()
				Picker("Output Device: ", selection: $currentInputDevice) {
					ForEach(TestingAudioInputDevice.allCases, id: \.self) {
						device in
						Text(device.rawValue)
					}
				}
				.frame(maxWidth: 250)
				
			}
			Divider()
			List {
				ForEach(0..<currentInputDevice.numChannels, id: \.self) {
					chan in
					VStack {
						HStack {
							Text("Channel[\(chan.description)]")
								.frame(width: 75)
							HStack {
								ForEach(0..<20) {
									level in
									Rectangle()
										.fill(level < 12 ? .green : level < 18 ? .yellow: .red)
										.frame(width: 10)
								}
							}
						}
					}
					
				}
			}
			Spacer()
		}
		.padding()
		.frame(minWidth: 800, minHeight: 800)
    }
}

#Preview {
    StaticTestingTemplate()
}
