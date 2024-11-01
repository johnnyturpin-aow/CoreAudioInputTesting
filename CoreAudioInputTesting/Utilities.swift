//
//  Utilities.swift
//  CoreAudioInputTesting
//
//  Created by Johnny Turpin on 11/1/24.
//

import Foundation
import CoreAudio


enum CAError: Error {
	case errorString(OSStatus, String)
	case componentNotFound
	case osStatus(OSStatus)
}

func throwIfError(_ error: OSStatus, _ operation: String = "") throws {
	guard error != noErr else { return }
	print("error: \(operation)")
	throw CAError.errorString(error, operation)
}


// relevant parts taken from MatrixMixerTest app
extension AudioStreamBasicDescription {
	
	var packednessIsSignificant: Bool {
		guard isPCM else { return false }
		return (sampleWordSize << 3) != mBitsPerChannel
	}
	var alignmentIsSignificant: Bool {
		return packednessIsSignificant || (mBitsPerChannel & 7) != 0
	}
	var isInterleaved: Bool {
		//return !(mFormatFlags & kAudioFormatFlagIsNonInterleaved)
		return !((mFormatFlags & kAudioFormatFlagIsNonInterleaved) > 0)
	}
	var numInterleavedChannels: UInt32 {
		return isInterleaved ? mChannelsPerFrame : 1
	}
	var numChannelStreams: UInt32 {
		return isInterleaved ? 1 : mChannelsPerFrame
	}
	var numChannels: UInt32 {
		return mChannelsPerFrame
	}
	
	var sampleWordSize: UInt32 {
		return (self.mBytesPerFrame > 0 && numInterleavedChannels > 0) ? mBytesPerFrame / numInterleavedChannels : 0
	}
	
	func framesToBytes(frames: UInt32) -> UInt32 {
		return frames * mBytesPerFrame
	}
	
	func bytesToFrames(bytes: UInt32) -> UInt32 {
		guard mBytesPerFrame > 0 else { return 0 }
		return bytes / mBytesPerFrame
	}
	
	var isPCM: Bool {
		return self.mFormatID == kAudioFormatLinearPCM
	}
	
	var isFloat: Bool {
		return isPCM && ((mFormatFlags & kAudioFormatFlagIsFloat) > 0)
	}
	
	
	func changeNumberOfChannels(channels: UInt32, interleaved: Bool) -> AudioStreamBasicDescription {
		var updatedASBD = self
		guard isPCM else { return updatedASBD }
		var wordSize = sampleWordSize
		if wordSize == 0 {
			wordSize = (mBitsPerChannel + 7) / 8
		}
		updatedASBD.mChannelsPerFrame = channels
		updatedASBD.mFramesPerPacket = 1
		if interleaved {
						updatedASBD.mBytesPerFrame = channels * wordSize
			updatedASBD.mBytesPerPacket = updatedASBD.mBytesPerFrame
			updatedASBD.mFormatFlags &= kAudioFormatFlagIsNonInterleaved
		} else {
			updatedASBD.mBytesPerFrame = wordSize
			updatedASBD.mBytesPerPacket = wordSize
			updatedASBD.mFormatFlags |= kAudioFormatFlagIsNonInterleaved
		}
		
		return updatedASBD
	}
}

