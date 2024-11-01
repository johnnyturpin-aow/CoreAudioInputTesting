//
//  AppViewModel.swift
//  CoreAudioInputTesting
//
//  Created by Johnny Turpin on 11/1/24.
//

import Foundation
import CoreAudio


class AppViewModel: ObservableObject {
	@Published var inputAudioDevices: [AudioDevice] = []
	@Published var outputAudioDevices: [AudioDevice] = []
	
	var levelGrabber: Timer?
	@Published var currentInputDevice: AudioDevice?
	@Published var currentOutputDevice: AudioDevice?
	
	@Published var isPlaying: Bool = false
	
	@Published var currentInputDeviceId: AudioDeviceID? { didSet {
		if let newId = self.currentInputDeviceId {
			print("changed currentInputDeviceId to: \(newId)")
			self.currentInputDevice = inputAudioDevices.first(where: { $0.id == newId })
			//updateMyAUGraphPlayer(deviceId: newId)
		}

	}}
	
	@Published var currentOutputDeviceId: AudioDeviceID? { didSet {
		if let newId = self.currentOutputDeviceId {
			print("changed currentOutputDeviceId to: \(newId)")
			self.currentOutputDevice = outputAudioDevices.first(where: { $0.id == newId })
		}

	}}
	
	var player: AUGraphInputToMixerToOutput = AUGraphInputToMixerToOutput()
	
	func startAUGraph() {
		guard let inputDevice = currentInputDevice, let outputDevice = currentOutputDevice else {
			// TODO: Show user error
			return
		}
		
		// just to be sure
		stopAUGraph()
		
		
		
		_ = player.setupForDevices(player: &player, inputDevice: inputDevice, outputDevice: outputDevice)
		player.startGraph()
		self.isPlaying = true
		
		levelGrabber?.invalidate()
		levelGrabber = Timer.scheduledTimer(withTimeInterval: 1/30, repeats: true) {
			[weak self] timer in
			DispatchQueue.global(qos: .userInteractive).async {
				self?.player.readLevels()
				// TODO: to display the levels in the UI - for now, all I want to see is print statements showing we got some valid levels
			}
		}
	}
	
	func stopAUGraph() {
		// if we have a player and it is running, then stop it
		if player.isRunning == true {
			player.stopGraph()
		}
		self.isPlaying = false
	}
	
	
	func populateAudioDevices() {
		populateAudioDevices(deviceType: .input)
		populateAudioDevices(deviceType: .output)
	}
	
	func populateAudioDevices(deviceType: AudioDeviceType) {
		
		var propsize:UInt32 = 0
		var address:AudioObjectPropertyAddress = AudioObjectPropertyAddress(
			mSelector:AudioObjectPropertySelector(kAudioHardwarePropertyDevices),
			mScope:AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal),
			mElement:AudioObjectPropertyElement(kAudioObjectPropertyElementMain))

		var result:OSStatus = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<AudioObjectPropertyAddress>.size), nil, &propsize)

		guard result == 0 else {
			print("Error = \(result.description)")
			return
		}
		let numDevices = Int(propsize / UInt32(MemoryLayout<AudioDeviceID>.size))
		var devids = [AudioDeviceID]()
		for _ in 0..<numDevices {
			devids.append(AudioDeviceID())
		}
		result = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propsize, &devids);
		guard result == 0 else {
			print("Error = \(result.description)")
			return
		}
		for id in devids {
			let audioDevice = AudioDevice(deviceID: id, deviceType: deviceType)
			var streamConfigAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: deviceType == .input ?  kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput, mElement: 0)
			result = AudioObjectGetPropertyDataSize(id, &streamConfigAddress, UInt32(MemoryLayout<AudioObjectPropertyAddress>.size), nil, &propsize)
			guard result == 0 else {
				print("error getting streamConfigAddress")
				return
			}
			let audioBufferList = AudioBufferList.allocate(maximumBuffers: Int(propsize))
			result = AudioObjectGetPropertyData(id, &streamConfigAddress, 0, nil, &propsize, audioBufferList.unsafeMutablePointer)
			var channelCount = 0
			let abl_numBuffers = Int(audioBufferList.unsafeMutablePointer.pointee.mNumberBuffers)
			for i in 0 ..< abl_numBuffers {
				channelCount = channelCount + Int(audioBufferList[i].mNumberChannels)
			}
			free(audioBufferList.unsafeMutablePointer)
			if channelCount > 0 {
				
				switch deviceType {
				case .input:
					print("Found input device[\(audioDevice.id.description)] '\(audioDevice.name ?? "N/A") with \(audioDevice.numChannels) channels")
					inputAudioDevices.append(audioDevice)
				case .output:
					print("Found output device[\(audioDevice.id.description)] '\(audioDevice.name ?? "N/A") with \(audioDevice.numChannels) channels")
					outputAudioDevices.append(audioDevice)
				}
				
			}
		}
	}
}

enum AudioDeviceType: String {
	case input
	case output
}

class AudioDevice: ObservableObject {
	var audioDeviceID:AudioDeviceID
	var id: UInt32 { return audioDeviceID }
	var deviceType: AudioDeviceType = .input
	
	@Published var displayableNumChannels: Int?
	@Published var displayableName: String?
	
	init(deviceID:AudioDeviceID, deviceType: AudioDeviceType) {
		self.audioDeviceID = deviceID
		self.deviceType = deviceType
		updateDisplayables()
	}
	
	func updateDisplayables() {
		displayableName = self.name ?? "N/A"
		displayableNumChannels = Int(self.numChannels)
	}
	
	var numChannels: UInt32 {
		get {
			var address:AudioObjectPropertyAddress = AudioObjectPropertyAddress(
				mSelector:AudioObjectPropertySelector(kAudioDevicePropertyStreamConfiguration),
				mScope:AudioObjectPropertyScope(deviceType == .input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput),
				mElement:0)

			var propsize:UInt32 = UInt32(MemoryLayout<CFString?>.size);
			var result:OSStatus = AudioObjectGetPropertyDataSize(self.audioDeviceID, &address, 0, nil, &propsize);
			if (result != 0) {
				return 0;
			}

			let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity:Int(propsize))
			result = AudioObjectGetPropertyData(self.audioDeviceID, &address, 0, nil, &propsize, bufferList);
			if (result != 0) {
				return 0
			}

			let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
			for bufferNum in 0..<buffers.count {
				if buffers[bufferNum].mNumberChannels > 0 {
					return buffers[bufferNum].mNumberChannels
				}
			}

			return 0
		}
	}
	var uid:String? {
		get {
			var address:AudioObjectPropertyAddress = AudioObjectPropertyAddress(
				mSelector:AudioObjectPropertySelector(kAudioDevicePropertyDeviceUID),
				mScope:AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal),
				mElement:AudioObjectPropertyElement(kAudioObjectPropertyElementMain))

			var name:CFString? = nil
			var propsize:UInt32 = UInt32(MemoryLayout<CFString?>.size)
			let result:OSStatus = AudioObjectGetPropertyData(self.audioDeviceID, &address, 0, nil, &propsize, &name)
			if (result != 0) {
				return nil
			}

			return name as String?
		}
	}
	var name:String? {
		get {
			var address:AudioObjectPropertyAddress = AudioObjectPropertyAddress(
				mSelector:AudioObjectPropertySelector(kAudioDevicePropertyDeviceNameCFString),
				mScope:AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal),
				mElement:AudioObjectPropertyElement(kAudioObjectPropertyElementMain))

			var name:CFString? = nil
			var propsize:UInt32 = UInt32(MemoryLayout<CFString?>.size)
			let result:OSStatus = AudioObjectGetPropertyData(self.audioDeviceID, &address, 0, nil, &propsize, &name)
			if (result != 0) {
				return nil
			}

			return name as String?
		}
	}
}
