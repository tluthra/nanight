import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import HaishinKit
@testable import RTMPHaishinKit
@testable import Nanight

@MainActor
struct PlaybackPipelineTests {
    @Test func videoQueueAdvancesWithoutAnAudioPlayer() async throws {
        let link = MediaLink()
        let output = await link.dequeue
        let collector = Task { () -> [CMTime] in
            var timestamps: [CMTime] = []
            for await sample in output { timestamps.append(sample.presentationTimeStamp) }
            return timestamps
        }
        await link.startRunning()
        for index in 0..<6 {
            await link.enqueue(try sample(at: CMTime(value: 9_000 + Int64(index), timescale: 30)))
        }
        try await Task.sleep(for: .milliseconds(350))
        await link.stopRunning()
        let timestamps = await collector.value
        #expect(timestamps.count == 6)
        #expect(timestamps.last == CMTime(value: 9_005, timescale: 30))
    }

    @Test func silentVideoKeepsAdvancingPastTheStallThreshold() async throws {
        let link = MediaLink()
        let output = await link.dequeue
        var tracker = NanightVideoFrameTracker()
        tracker.startMonitoring(at: ProcessInfo.processInfo.systemUptime)
        let collector = Task { () -> Int in
            var count = 0
            for await frame in output {
                count += 1
                tracker.recordFrame(presentationTimeStamp: frame.presentationTimeStamp, at: ProcessInfo.processInfo.systemUptime)
            }
            return count
        }
        await link.startRunning()
        // More than the three-second watchdog threshold, with no audio clock.
        for index in 0..<120 {
            await link.enqueue(try sample(at: CMTime(value: 90_000 + Int64(index), timescale: 30)))
            try await Task.sleep(for: .milliseconds(34))
        }
        let state = tracker.state(at: ProcessInfo.processInfo.systemUptime)
        await link.stopRunning()
        let count = await collector.value
        #expect(count >= 115)
        #expect(state == .live)
    }

    @Test func videoClockResetsAcrossStopAndStart() async throws {
        let link = MediaLink()
        for origin in [9_000, 0, 18_000] {
            let output = await link.dequeue
            let collector = Task { () -> Int in
                var count = 0
                for await _ in output { count += 1 }
                return count
            }
            await link.startRunning()
            // Delay first frame to ensure the clock anchors on data, not connection start.
            try await Task.sleep(for: .milliseconds(30))
            for index in 0..<6 {
                await link.enqueue(try sample(at: CMTime(value: Int64(origin + index), timescale: 30)))
            }
            try await Task.sleep(for: .milliseconds(300))
            await link.stopRunning()
            #expect(await collector.value == 6)
        }
    }

    @Test func queuedAudioPacketsOwnTheirBytesAndDescriptions() throws {
        var description = AudioStreamBasicDescription(mSampleRate: 44_100, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 2, mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0, mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
        let format = try #require(AVAudioFormat(streamDescription: &description))
        func message(size: Int, byte: UInt8) throws -> RTMPAudioMessage {
            let source = AVAudioCompressedBuffer(format: format, packetCapacity: 1, maximumPacketSize: size)
            source.byteLength = UInt32(size)
            source.packetCount = 1
            source.data.initializeMemory(as: UInt8.self, repeating: byte, count: size)
            return try #require(RTMPAudioMessage(streamId: 1, timestamp: 0, audioBuffer: source))
        }
        let firstMessage = try message(size: 365, byte: 0x37)
        let first = try #require(firstMessage.makeAudioBuffer(format: format))
        let second = try #require(try message(size: 364, byte: 0x42).makeAudioBuffer(format: format))
        #expect(first.data != second.data)
        #expect(first.byteLength == 365)
        #expect(first.packetDescriptions?.pointee.mDataByteSize == 365)
        #expect(first.data.load(as: UInt8.self) == 0x37)
        #expect(second.byteLength == 364)
        #expect(second.packetDescriptions?.pointee.mDataByteSize == 364)
        #expect(second.data.load(as: UInt8.self) == 0x42)
        let tooSmall = AVAudioCompressedBuffer(format: format, packetCapacity: 1, maximumPacketSize: 2)
        firstMessage.copyMemory(tooSmall)
        #expect(tooSmall.byteLength == 0)
        #expect(RTMPAudioMessage(RTMPChunkMessageHeader()).makeAudioBuffer(format: format) == nil)
    }

    @Test func decodedFramesArePresentedWithoutASecondClock() throws {
        let frame = try sample(at: CMTime(value: 90_000, timescale: 30))
        NanightVideoPresentation.displayImmediately(frame)
        let attachments = try #require(CMSampleBufferGetSampleAttachmentsArray(frame, createIfNecessary: false))
        let entry = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFDictionary.self)
        let value = try #require(CFDictionaryGetValue(entry, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque()))
        #expect(value == UnsafeRawPointer(Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()))
    }

    @Test func realAACPacketsDecodeContinuously() async throws {
        let pcm = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let aac = try #require(AVAudioFormat(settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1]))
        let encoder = try #require(AVAudioConverter(from: pcm, to: aac))
        var offset = 0
        var packets: [AVAudioCompressedBuffer] = []
        for _ in 0..<80 {
            let encoded = AVAudioCompressedBuffer(format: aac, packetCapacity: 1, maximumPacketSize: encoder.maximumOutputPacketSize)
            var error: NSError?
            let status = encoder.convert(to: encoded, error: &error) { requested, inputStatus in
                let count = min(Int(requested), 44_100 - offset)
                guard count > 0 else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                let input = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: AVAudioFrameCount(count))!
                input.frameLength = AVAudioFrameCount(count)
                for index in 0..<count {
                    input.floatChannelData![0][index] = Float(sin(Double(offset + index) * 2 * .pi * 440 / 44_100) * 0.2)
                }
                offset += count
                inputStatus.pointee = .haveData
                return input
            }
            #expect(error == nil)
            if encoded.byteLength > 0 { packets.append(encoded) }
            if status == .endOfStream { break }
        }
        #expect(packets.count >= 40)
        let codec = AudioCodec()
        codec.settings.format = .pcm
        let output = codec.outputStream
        codec.startRunning()
        for (index, packet) in packets.enumerated() {
            let message = try #require(RTMPAudioMessage(streamId: 1, timestamp: UInt32(index * 23), audioBuffer: packet))
            let ownedPacket = try #require(message.makeAudioBuffer(format: aac))
            codec.append(ownedPacket, when: AVAudioTime(sampleTime: Int64(index * 1024), atRate: 44_100))
        }
        codec.stopRunning()
        var frames = 0
        var peak: Float = 0
        for await (buffer, _) in output {
            let decoded = try #require(buffer as? AVAudioPCMBuffer)
            frames += Int(decoded.frameLength)
            for index in 0..<Int(decoded.frameLength) {
                peak = max(peak, abs(decoded.floatChannelData![0][index]))
            }
        }
        #expect(frames >= 44_100)
        #expect(frames <= packets.count * 1024)
        #expect(peak > 0.1)
    }

    private func sample(at time: CMTime) throws -> CMSampleBuffer {
        var pixel: CVPixelBuffer?
        #expect(CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA, nil, &pixel) == kCVReturnSuccess)
        let image = try #require(pixel)
        var format: CMVideoFormatDescription?
        #expect(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image, formatDescriptionOut: &format) == noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        #expect(CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image, dataReady: true, makeDataReadyCallback: nil, refcon: nil, formatDescription: try #require(format), sampleTiming: &timing, sampleBufferOut: &sample) == noErr)
        return try #require(sample)
    }
}
