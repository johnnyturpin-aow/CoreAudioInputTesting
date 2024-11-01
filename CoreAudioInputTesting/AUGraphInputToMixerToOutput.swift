//
//  AUGraphInputToMixerToOutput.swift
//  CoreAudioInputTesting
//
//  Created by Johnny Turpin on 11/1/24.
//

import Foundation
import CoreAudio
import AVFoundation

class AUGraphInputToMixerToOutput {
	var inputDeviceId: AudioDeviceID!
	var outputDeviceId: AudioDeviceID!
	var numInputChannels: Int = 0
	
	var inputMetersAvgPwr: [Int:[Float32]] = [:]
	var inputMetersPeakHold: [Int:[Float32]] = [:]
	
	// warning: we are assuming the chosen output device has at least 2 channels to keep things simple
	let numOutputChannels: Int = 2
	
	var inputAU: AudioUnit!
	var mixerNode: AUNode = AUNode()
	var mixerAU: AudioUnit!
	
	var outputNode: AUNode = AUNode()
	var outputAU: AudioUnit!
	
	var deviceFormat = AudioStreamBasicDescription()
	var streamFormat = AudioStreamBasicDescription()
	var graph: AUGraph!
	
	var inputSafetyOffset: UInt32 = 0
	var outputSafetyOffset: UInt32 = 0
	var inputBufferSizeFrames = UInt32(0)
	var outputBufferSizeFrames: UInt32 = 0
	
	var inputBuffer: UnsafeMutableAudioBufferListPointer! // UnsafeMutablePointer<AudioBufferList>!
	var ringBuffer: RingBufferWrapper!
	var firstInputSampleTime = Float64(-1)
	var firstOutputSampleTime = Float64(-1)
	var inToOutSampleTimeOffset = Float64(-1)
	
	var isRunning: Bool = false
	
	// counters used to limit debugging prints
	var levelsCounter: Int = 0
	var counter: Int = 0
	
	
	func startGraph() {
		var err: OSStatus = noErr
		
		do {
			
			err = AudioOutputUnitStart(self.inputAU)
			try throwIfError(err, "AudioOutputUnitStart")
			
			err = AUGraphStart(self.graph)
			try throwIfError(err, "AUGraphStart")
			
			// I believe the element # here refers to the bus #?
			err = mixerEnableInput(inputChannel: 0, enable: 1.0)
			try throwIfError(err, "mixerEnableInput")
			err = mixerEnableOutput(outputChannel: 0, enable: 1.0)
			try throwIfError(err, "mixerEnableOutput")
			
			for chan in 0..<numInputChannels {
				err = mixerSetInputChannelVolume(volume: 1.0, channel: UInt32(chan))
				err = mixerSetMatrixVolume(volume: 1.0, inputChannel: UInt32(chan), outputChannel: chan % 2 == 0 ? 0 : 1)
			}
			
			computeThroughOffset()
			
			CAShowFile(UnsafeMutableRawPointer(self.graph), stdout)
			print("MixerAU: Input Busses -------")
			printBuses(au: self.mixerAU, scope: kAudioUnitScope_Input)
			print("MixerAU: Output Busses -------")
			printBuses(au: self.mixerAU, scope: kAudioUnitScope_Output)
			
			firstInputSampleTime = -1
			firstOutputSampleTime = -1
			
			isRunning = true
		} catch {
			print("got an error while Starting Graph!")
		}
	}
	
	
	func stopGraph() {
		var err: OSStatus = noErr
		
		do {
			err = AudioOutputUnitStop(self.inputAU)
			try throwIfError(err, "AudioOutputUnitStop")
			
			err = AUGraphStop(self.graph)
			try throwIfError(err, "AUGraphStop")
			
			isRunning = false
		} catch {
			print("got an error while Stoping Graph!")
		}
	}
	
	
	func readLevels() {
		var err: OSStatus = noErr
		var averageDecibles: AudioUnitParameterValue = 0
		var peakHoldDecibles: AudioUnitParameterValue = 0
		
		self.inputMetersAvgPwr = [:]
		self.inputMetersPeakHold = [:]
		
		for j in 0..<2 {
			self.inputMetersAvgPwr[j] = Array(repeating: AudioUnitParameterValue(0), count: numInputChannels)
			self.inputMetersPeakHold[j] = Array(repeating: AudioUnitParameterValue(0), count: numInputChannels)
			for i in 0..<numInputChannels {
				
				let element: UInt32 = (UInt32(i) << 16) | UInt32(j)
				err = AudioUnitGetParameter(self.mixerAU, kMatrixMixerParam_PostAveragePower, kAudioUnitScope_Global, element, &averageDecibles)
				err = AudioUnitGetParameter(self.mixerAU, kMatrixMixerParam_PostPeakHoldLevel, kAudioUnitScope_Global, element, &peakHoldDecibles)
				self.inputMetersAvgPwr[j]?[i] = averageDecibles
				self.inputMetersPeakHold[j]?[i] = peakHoldDecibles

				// sanity print to when we get actual values
				if levelsCounter % 100 == 0 {
					if err != noErr {
						print("we got a problem reading meters")
					}
					if averageDecibles > -50 {
						print("[\(i),\(j)] = \(averageDecibles)")
						print("[\(i),\(j)] = \(peakHoldDecibles)")
					}
				}
			}
		}
		levelsCounter += 1
	}
	
	// for this demo, we are going to assume our output device has at least 2 channels
	// input device can have any number of channels
	/// This is what our AUGraph looks like
	/*
	 [---------------]              [---------------]            [---------------]
	 |               |              |               |            |               |
	 | AUHAL (Input) | =>  [B1] =>  | MatrixMixerAU | => [B2] => | AUHAL(output) |
	 |               |              |               |            |               |
	 [---------------]              [---------------]            [---------------]
	 
	 B1 = Single bus with n number of channels defined by the number of input channels available on the input device
	 B2 = Single bus with 2 channels going to default output device
	 
	 In my testing environment, Input Device is an Audeint iD14 USB-C Audio Device (12 input channels and 6 output channels)
	 
	 Ultimate goal is to replace the AUHAL output device with a kAudioUnitSubType_GenericOutput AU - but this doesn't seem to pull any samples from the ringer buffer
	 
	 */
	func setupForDevices(player: UnsafeMutablePointer<AUGraphInputToMixerToOutput>, inputDevice: AudioDevice, outputDevice: AudioDevice) -> OSStatus {
		var err: OSStatus = noErr
		var propSize = UInt32(MemoryLayout<UInt32>.size)
		
		self.inputDeviceId = inputDevice.audioDeviceID
		self.outputDeviceId = outputDevice.audioDeviceID
		
		
		var inputCD: AudioComponentDescription = AudioComponentDescription()
		inputCD.componentType = kAudioUnitType_Output
		inputCD.componentSubType = kAudioUnitSubType_HALOutput
		inputCD.componentManufacturer = kAudioUnitManufacturer_Apple
		inputCD.componentFlags = 0
		inputCD.componentFlagsMask = 0
		

		
		var disableFlag = UInt32(0)
		var enableFlag = UInt32(1)
		let outputBus = AudioUnitScope(0)
		let inputBus = AudioUnitScope(1)
		
		do {
			
			// MARK: -Setup AUHAL (Audio Input Device)
			
			let comp = AudioComponentFindNext(nil, &inputCD)
			guard let comp = comp else { return -1 }
			
			err = AudioComponentInstanceNew(comp, &inputAU)
			try throwIfError(err, "AudioComponentInstanceNew")
			
			//AUHAL needs to be initialized before anything is done to it
			err = AudioUnitInitialize(self.inputAU);
			try throwIfError(err, "AudioUnitInitialize")
			
			// enable I/O on inputBus
			propSize = UInt32(MemoryLayout<UInt32>.size)
			err = AudioUnitSetProperty(self.inputAU, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, inputBus, &enableFlag, propSize)
			try throwIfError(err, "kAudioOutputUnitProperty_EnableIO: kAudioUnitScope_Input - enableFlag")
			
			// disable I/O on outputBus
			err = AudioUnitSetProperty(self.inputAU, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, outputBus, &disableFlag, propSize)
			try throwIfError(err, "kAudioOutputUnitProperty_EnableIO: kAudioUnitScope_Output - disableOutput")
			
			
			
			// set outputDevice as Current
			var inputProp: AudioObjectPropertyAddress = AudioObjectPropertyAddress()
			inputProp.mSelector = kAudioDevicePropertySafetyOffset
			inputProp.mScope = kAudioDevicePropertyScopeInput
			inputProp.mElement = 0
			propSize = UInt32(MemoryLayout<AudioObjectPropertyAddress>.size)
			
			// before setting output as current, let's read safety offset and bufferSizeFrames
			err = AudioObjectGetPropertyData(self.inputDeviceId, &inputProp, 0, nil, &propSize, &inputSafetyOffset)
			try throwIfError(err, "kAudioDevicePropertyBufferFrameSize: bufferSizeFrames")
			
			inputProp.mSelector = kAudioDevicePropertyBufferFrameSize
			err = AudioObjectGetPropertyData(self.inputDeviceId, &inputProp, 0, nil, &propSize, &inputBufferSizeFrames)
			try throwIfError(err, "kAudioDevicePropertyBufferFrameSize: bufferSizeFrames")
			
			// set current input device to deviceID passed in
			propSize = UInt32(MemoryLayout<AudioDeviceID>.size)
			err = AudioUnitSetProperty(self.inputAU, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &self.inputDeviceId, propSize)
			try throwIfError(err, "kAudioUnitProperty_StreamFormat: deviceFormat")
			
			print("default DeviceID = \(self.inputDeviceId.description)")

			//numInputChannels = getNumChannelsOfDevice(deviceId: self.inputDeviceId, scope: kAudioDevicePropertyScopeInput)
			numInputChannels = Int(inputDevice.numChannels)
			
			guard numInputChannels > 0 else { return -1 }
			
			// set channelMap to straight through for each channel
			var channelMap:  [Int32] = []
			for i in 0..<numInputChannels {
				channelMap.append(Int32(i))
			}
			propSize = UInt32(MemoryLayout<Int32>.size) * UInt32(channelMap.count)
			err = AudioUnitSetProperty(inputAU, kAudioOutputUnitProperty_ChannelMap, kAudioUnitScope_Input, 1, &channelMap, propSize)
			try throwIfError(err, "EnableIO: kAudioOutputUnitProperty_ChannelMap")
			
			
			// setup Input Callback Proc
			var inputCallbackStruct = AURenderCallbackStruct(inputProc: audioInputCallbackProc, inputProcRefCon: player)
			err = AudioUnitSetProperty(self.inputAU,  kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &inputCallbackStruct, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
			try throwIfError(err, "kAudioOutputUnitProperty_SetInputCallback")
			
			err = AudioUnitInitialize(self.inputAU)
			try throwIfError(err, "AudioUnitInitialize after channelMap and callback")
			
			
			// MARK: - Setup AUGraph
			/// AUHAL Input Device[numChannels] -> MixerAU -> OutputAU
			///
			///
			///
			// create AUGraph for MatrixMixer (numInputChannels will be the number of input channels on the input mixer)
			err = NewAUGraph(&self.graph)
			try throwIfError(err, "NewAUGraph")

			var mixerCD: AudioComponentDescription = AudioComponentDescription()
			mixerCD.componentType = kAudioUnitType_Mixer
			mixerCD.componentSubType = kAudioUnitSubType_MatrixMixer
			mixerCD.componentManufacturer = kAudioUnitManufacturer_Apple
			mixerCD.componentFlags = 0
			mixerCD.componentFlagsMask = 0
			
			var outputCD: AudioComponentDescription = AudioComponentDescription()
			outputCD.componentType = kAudioUnitType_Output
			
			/// Note: kAudioUnitSubType_GenericOutput does not seem to automatically pull samples from RenderProc like the DefaultOutput Device does
			/// Need to investigate how to use GenericOutput AU
			/// So for now, we use kAudioUnitSubType_DefaultOutput and just set the output volume of the mixer to 0
			//outputCD.componentSubType = kAudioUnitSubType_GenericOutput
			outputCD.componentSubType = kAudioUnitSubType_DefaultOutput
			outputCD.componentManufacturer = kAudioUnitManufacturer_Apple
			outputCD.componentFlags = 0
			outputCD.componentFlagsMask = 0
			
			// add the mixerNode
			err = AUGraphAddNode(self.graph, &mixerCD, &self.mixerNode)
			try throwIfError(err, "AUGraphAddNode: mixerNode")
			
			// add generic output node
			err = AUGraphAddNode(self.graph, &outputCD, &self.outputNode)
			try throwIfError(err, "AUGraphAddNode: outputNode")
			
			// don't initialize the graph until our buffers and stream formats are set up?
			err = AUGraphConnectNodeInput(graph, mixerNode, 0, self.outputNode, 0)
			try throwIfError(err, "AUGraphConnectNodeInput: mixerAU -> outputAU")
			
			// we can't call GraphNodeInfo until we open the AUGraph?
			err = AUGraphOpen(self.graph)
			try throwIfError(err, "AUGraphOpen")
			
			// get reference to mixerAU
			err = AUGraphNodeInfo(self.graph, self.mixerNode, nil, &self.mixerAU)
			try throwIfError(err, "AUGraphNodeInfo: mixerAU")
			

			// get reference to outputAU
			err = AUGraphNodeInfo(self.graph, self.outputNode, nil, &self.outputAU)
			try throwIfError(err, "AUGraphNodeInfo: mixerAU")
			
			// set outputDevice as Current
			var outputProp: AudioObjectPropertyAddress = AudioObjectPropertyAddress()
			outputProp.mSelector = kAudioDevicePropertySafetyOffset
			outputProp.mScope = kAudioDevicePropertyScopeOutput
			outputProp.mElement = 0
			propSize = UInt32(MemoryLayout<AudioObjectPropertyAddress>.size)
			
			// before setting output as current, let's read safety offset and bufferSizeFrames
			err = AudioObjectGetPropertyData(self.outputDeviceId, &outputProp, 0, nil, &propSize, &outputSafetyOffset)
			try throwIfError(err, "kAudioDevicePropertyBufferFrameSize: bufferSizeFrames")
			
			outputProp.mSelector = kAudioDevicePropertyBufferFrameSize
			err = AudioObjectGetPropertyData(self.outputDeviceId, &outputProp, 0, nil, &propSize, &outputBufferSizeFrames)
			try throwIfError(err, "kAudioDevicePropertyBufferFrameSize: bufferSizeFrames")
			
			// finally, set CurrentDevice to passed in outputDeviceId
			err = AudioUnitSetProperty(self.outputAU, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &self.outputDeviceId, propSize);
			try throwIfError(err, "kAudioDevicePropertyBufferFrameSize: bufferSizeFrames")
			
			// MARK: - Setup Buffers and Stream Formats
			
			// get size if I/O buffers for input device
			propSize = UInt32(MemoryLayout<UInt32>.size)
			err = AudioUnitGetProperty(self.inputAU, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0, &inputBufferSizeFrames, &propSize)
			try throwIfError(err, "kAudioDevicePropertyBufferFrameSize: bufferSizeFrames")
			
			print("inputBufferSizeFrames = \(inputBufferSizeFrames)")
			// get the input device format
			// the numChannels here should match the numChannels we calculated earlier?
			propSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
			err = AudioUnitGetProperty(self.inputAU, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, inputBus, &deviceFormat, &propSize)
			try throwIfError(err, "kAudioUnitProperty_StreamFormat: deviceFormat")
			
			print("deviceFormat: \(deviceFormat)")
			
			guard deviceFormat.mChannelsPerFrame == numInputChannels else { return -2 }
			
			print ("deviceFormat is \(deviceFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved > 0 ? "non-" : "")interleaved")
			
			// get the default stream format of the output of the inputAU (sample rate may be different than the device sample rate)
			// we want to set this stream format to match the sample rate of the input device as well as the correct num channels
			
			var format = AudioStreamBasicDescription()
			propSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
			err = AudioUnitGetProperty(self.inputAU, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, inputBus, &format, &propSize)
			try throwIfError(err, "kAudioUnitProperty_StreamFormat: streamFormat")
			
			print("streamFormat: \(format)")
			print ("streamFormat is \(format.isInterleaved ? "Interleaved" : "Non-Interleaved")")
			
			/*
			 deviceFormat: AudioStreamBasicDescription(mSampleRate: 48000.0, mFormatID: 1819304813, mFormatFlags: 9, mBytesPerPacket: 48, mFramesPerPacket: 1, mBytesPerFrame: 48, mChannelsPerFrame: 12, mBitsPerChannel: 32, mReserved: 0)
			 streamFormat: AudioStreamBasicDescription(mSampleRate: 44100.0, mFormatID: 1819304813, mFormatFlags: 41, mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
			 */
			
			self.streamFormat = format.changeNumberOfChannels(channels: UInt32(numInputChannels), interleaved: false)
			self.streamFormat.mSampleRate = deviceFormat.mSampleRate
			
			// set the streamFormat of the inputAU output to our common format
			print("updating streamFormat to device sample rate and \(self.numInputChannels) channelsPerFrame...")
			propSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
			err = AudioUnitSetProperty(self.inputAU, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, inputBus, &streamFormat, propSize)
			try throwIfError(err, "setting kAudioUnitProperty_StreamFormat: of inputAT inputBus to sample Rate = \(streamFormat.mSampleRate)")
			
			
			// sanity check to test if our change to streamFormat was accepted
			var compareFormat = AudioStreamBasicDescription()
			propSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
			err = AudioUnitGetProperty(self.inputAU, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, inputBus, &compareFormat, &propSize)
			try throwIfError(err, "kAudioUnitProperty_StreamFormat: compareFormat")
			
			print("streamFormat after setting changes: \(compareFormat)")
			

			let bufferSizeBytes = inputBufferSizeFrames * UInt32(MemoryLayout<Float32>.size)
			inputBuffer = AudioBufferList.allocate(maximumBuffers: numInputChannels)
			for i in 0..<numInputChannels {
				inputBuffer[i] = AudioBuffer(mNumberChannels: 1,
									 mDataByteSize: bufferSizeBytes,
									 mData: malloc(Int(bufferSizeBytes)))
			}
			ringBuffer = CreateRingBuffer()
			AllocateBuffer(ringBuffer, Int32(streamFormat.mChannelsPerFrame), streamFormat.mBytesPerFrame, inputBufferSizeFrames * 20)
			
			// MARK: - Setup MatrixMixer
			
			// set mixer to have 1 input bus and 1 output bus
			var numBuses: UInt32 = 1
			
			propSize = UInt32(MemoryLayout<UInt32>.size)
			err = AudioUnitSetProperty(self.mixerAU, kAudioUnitProperty_ElementCount, kAudioUnitScope_Input, 0, &numBuses, propSize)
			try throwIfError(err, "set num inputBusses on MatrixMixer")
			
			// set mixer to have 1 output bus
			err = AudioUnitSetProperty(self.mixerAU, kAudioUnitProperty_ElementCount, kAudioUnitScope_Output, 0, &numBuses, propSize)
			try throwIfError(err, "set num inputBusses on MatrixMixer")
			
			// set the streamFormat for the input bus of the mixerAU to our common input format
			propSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
			err = AudioUnitSetProperty(self.mixerAU, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &streamFormat, propSize)
			try throwIfError(err, "setting kAudioUnitProperty_StreamFormat: of inputAT inputBus to sample Rate = \(streamFormat.mSampleRate)")
			print("setting kAudioUnitProperty_StreamFormat: of mixerAU:AudioUnitScope_Input to sample Rate = \(streamFormat.mSampleRate), numChannels = \(streamFormat.mChannelsPerFrame)")
			
			var mixerOutputFormat: AudioStreamBasicDescription = AudioStreamBasicDescription()
			propSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
			err = AudioUnitGetProperty(self.mixerAU, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &mixerOutputFormat, &propSize)
			try throwIfError(err, "kAudioUnitProperty_StreamFormat: streamFormat")

			print("mixerOutputFormat: \(mixerOutputFormat)")
			
			// set format of mixer output to a simple 2channel output
			var mixerOutput2Chan = mixerOutputFormat.changeNumberOfChannels(channels: UInt32(numOutputChannels), interleaved: false)
			mixerOutput2Chan.mSampleRate = self.streamFormat.mSampleRate
			err = AudioUnitSetProperty(self.mixerAU, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &mixerOutput2Chan, propSize)
			try throwIfError(err, "kAudioUnitProperty_StreamFormat: mixerAU")
			
			print("mixerOutput2Chan: \(mixerOutput2Chan)")
			
			// turn metering on (for input bus)
			var meteringode: UInt32 = 1
			propSize = UInt32(MemoryLayout<UInt32>.size)
			err = AudioUnitSetProperty(self.mixerAU, kAudioUnitProperty_MeteringMode, kAudioUnitScope_Global, 0, &meteringode, propSize)
			try throwIfError(err, "kAudioUnitProperty_MeteringMode: mixerAU <- kAudioUnitScope_Output")
			
			// set renderCallback for mixerAU input bus (n channels)
			var graphRenderCallback = AURenderCallbackStruct(inputProc: mixerGraphRenderProc, inputProcRefCon: player)
			err = AudioUnitSetProperty(self.mixerAU,  kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Global, 0, &graphRenderCallback, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
			try throwIfError(err, "kAudioUnitProperty_SetRenderCallback: outputAU")
			
//			// set input format of outputAU to match output format of mixer
			propSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
			err = AudioUnitSetProperty(self.outputAU, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &mixerOutput2Chan, propSize)
			try throwIfError(err, "kAudioUnitProperty_StreamFormat: mixerAU")
			
			// final step is to initialize graph after setting everything up
			err = AUGraphInitialize(self.graph)
			try throwIfError(err, "AUGraphInitialize")
			
		} catch {
			print("we got a problem: createInputUnit")
		}
		

		return err
	}
	
	func mixerSetInputChannelVolume(volume: Float32, channel: UInt32) -> OSStatus {
		var err: OSStatus = noErr
		err = AudioUnitSetParameter(self.mixerAU, kMatrixMixerParam_Volume, kAudioUnitScope_Input, channel, volume, 0)
		return err
	}
	
	func mixerSetOutputChannelVolume(volume: Float32, channel: UInt32) -> OSStatus {
		var err: OSStatus = noErr
		err = AudioUnitSetParameter(self.mixerAU, kMatrixMixerParam_Volume, kAudioUnitScope_Output, channel, volume, 0)
		return err
	}
	
	
	func mixerSetMatrixVolume(volume: Float32, inputChannel: UInt32,  outputChannel: UInt32) -> OSStatus {
		var err: OSStatus = noErr
		let element: UInt32 = (inputChannel << 16) | (outputChannel & 0x0000ffff)
		err = AudioUnitSetParameter(self.mixerAU, kMatrixMixerParam_Volume, kAudioUnitScope_Global, element, volume, 0)
		return err
	}
	
	func mixerSetMasterVolume(volume: Float32) -> OSStatus {
		var err: OSStatus = noErr
		err = AudioUnitSetParameter(self.mixerAU, kMatrixMixerParam_Volume, kAudioUnitScope_Global, 0xFFFFFFFF, volume, 0)
		return err
	}
	
	func mixerEnableInput(inputChannel: UInt32, enable: Float32) -> OSStatus {
		var err: OSStatus = noErr
		err = AudioUnitSetParameter(self.mixerAU, kMatrixMixerParam_Enable, kAudioUnitScope_Input, inputChannel, enable, 0);
		return err
	}
	
	func mixerEnableOutput(outputChannel: UInt32, enable: Float32) -> OSStatus {
		var err: OSStatus = noErr
		err = AudioUnitSetParameter(self.mixerAU, kMatrixMixerParam_Enable, kAudioUnitScope_Output, outputChannel, enable, 0);
		return err
	}
	
	func computeThroughOffset() {
		inToOutSampleTimeOffset = Float64(inputSafetyOffset + inputBufferSizeFrames + outputSafetyOffset + outputBufferSizeFrames)
	}
	
	func getNumChannelsOfAUElement(au: AudioUnit, scope: AudioUnitScope, element: AudioUnitElement) -> UInt32 {
		var numChannels: UInt32  = 0
		var err: OSStatus = noErr
		var desc = AudioStreamBasicDescription()
		var propSize: UInt32 = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
		err = AudioUnitGetProperty(au, kAudioUnitProperty_StreamFormat, scope, element, &desc, &propSize)
		if err == noErr {
			numChannels = desc.mChannelsPerFrame
		}
		return numChannels
	}
	
	func printBuses(au: AudioUnit, scope: AudioUnitScope) {
		var err: OSStatus = noErr
		var busCount: UInt32 = 0
		var propSize: UInt32 = UInt32(MemoryLayout<UInt32>.size)
		
		err = AudioUnitGetProperty(au, kAudioUnitProperty_ElementCount, scope, 0, &busCount, &propSize)
		guard err == noErr else { return }
		for i in 0..<busCount {
			var val: Float32 = 0
			var numChannels: UInt32 = getNumChannelsOfAUElement(au: au, scope: scope, element: i)
			err = AudioUnitGetParameter (au, kMatrixMixerParam_Enable, scope, i, &val)
			let frameCharStart = val != 0 ? "[" : "{"
			let frameCharEnd = val != 0 ? "]" : "}"
			
			print("\(i): \(frameCharStart)\(numChannels)\(frameCharEnd) : \(val != 0 ? "ON" : "OFF")")

		}
	}
}


// takes frames from inputAU and stores into inputRingBuffer
func audioInputCallbackProc(inRefCon: UnsafeMutableRawPointer,
					 ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
					 inTimeStamp: UnsafePointer<AudioTimeStamp>,
					 inBusNumber: UInt32,
					 inNumberFrames: UInt32,
					 ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
	
	var err: OSStatus = noErr
	let player = inRefCon.assumingMemoryBound(to: AUGraphInputToMixerToOutput.self).pointee
	
	if player.firstInputSampleTime < 0 {
		player.firstInputSampleTime = inTimeStamp.pointee.mSampleTime
		print("Got our first samples... setting firstInputSampleTime to: \(player.firstInputSampleTime)")
	}
	
	err = AudioUnitRender(player.inputAU, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, player.inputBuffer.unsafeMutablePointer)
	
	if err == 0 {
		err = StoreBuffer(player.ringBuffer, player.inputBuffer.unsafeMutablePointer, inNumberFrames, Int64(inTimeStamp.pointee.mSampleTime))

	} else {
		if player.counter % 100 == 0 {
			print("AudioUnitRender: err = \(err)")
		}
	}
	
//	if player.counter % 100 == 0 {
//		print("AudioUnitRender: Stored \(inNumberFrames) @ \(inTimeStamp.pointee.mSampleTime)")
//		print("firstInputSampleTime = \(player.firstInputSampleTime)")
//		print("firstOutputSampleTime = \(player.firstOutputSampleTime)")
//		print("inToOutSampleTimeOffset = \(player.inToOutSampleTimeOffset)")
//	}
//	player.counter += 1
	
	return err
}

// takes samples stored in inputRingBuffer and fetches them into our AUGraph
func mixerGraphRenderProc(inRefCon: UnsafeMutableRawPointer,
					 ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
					 inTimeStamp: UnsafePointer<AudioTimeStamp>,
					 inBusNumber: UInt32,
					 inNumberFrames: UInt32,
					 ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
	
	var err: OSStatus = noErr
	let player = inRefCon.assumingMemoryBound(to: AUGraphInputToMixerToOutput.self).pointee
	var inTS = AudioTimeStamp()
	var outTS = AudioTimeStamp()
	
	if player.firstInputSampleTime < 0 {
		// we need to wait until we got  data
		return noErr
	}
	
	err = AudioDeviceGetCurrentTime(player.inputDeviceId, &inTS)
	if err != noErr {
		return noErr
	}
	
	err = AudioDeviceGetCurrentTime(player.outputDeviceId, &outTS)
	
	var rate = 1.0
	
	if player.firstOutputSampleTime < 0 {
		player.firstOutputSampleTime = inTimeStamp.pointee.mSampleTime
		let delta = player.firstInputSampleTime - player.firstOutputSampleTime
		player.computeThroughOffset()
		if delta < 0 {
			player.inToOutSampleTimeOffset -= delta
		} else {
			player.inToOutSampleTimeOffset = -delta + player.inToOutSampleTimeOffset
		}
		return noErr
	}
	
	err = FetchBuffer(player.ringBuffer, ioData, inNumberFrames, Int64(inTimeStamp.pointee.mSampleTime - player.inToOutSampleTimeOffset))
	if err != noErr {
		var bufferStartTime: SampleTime = 0
		var bufferEndTime: SampleTime = 0
		GetTimeBoundsFromBuffer(player.ringBuffer, &bufferStartTime, &bufferEndTime)
		player.inToOutSampleTimeOffset = inTimeStamp.pointee.mSampleTime - Float64(bufferStartTime)
	}
	
	return err
}
