import Foundation
import AVFoundation

@main struct AudioBufferChecks {
    static func main() throws {
        let directory = URL(fileURLWithPath: "tmp/audio-lifecycle", isDirectory: true)
        for rate in [16000.0, 44100.0, 48000.0] {
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
            let url = directory.appendingPathComponent("buffer-\(Int(rate)).wav")
            let sink = try RecordingSink(format: format, url: url, levels: { _ in })
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
            var remaining = Int(rate)
            while remaining > 0 {
                let count = min(1024, remaining)
                buffer.frameLength = AVAudioFrameCount(count)
                for i in 0..<count { buffer.floatChannelData![0][i] = 0.25 }
                sink.append(buffer)
                // A caller may recycle its storage as soon as the tap returns.
                for i in 0..<count { buffer.floatChannelData![0][i] = 0.75 }
                remaining -= count
            }
            precondition(sink.finish() == url)
            let file = try AVAudioFile(forReading: url)
            print("Converted \(Int(rate)) Hz: \(file.length) frames")
            precondition(file.processingFormat.sampleRate == 16000)
            precondition(abs(file.length - 16000) <= 1, "Recording tail was lost")
            let read = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
            try file.read(into: read)
            let middle = read.floatChannelData![0][Int(read.frameLength) / 2]
            precondition(abs(middle - 0.25) < 0.01, "Tap buffer storage was reused")
            sink.append(buffer)
            _ = sink.finish()
            let reopened = try AVAudioFile(forReading: url)
            precondition(reopened.length == file.length, "Late callback wrote to closed file")
            try FileManager.default.removeItem(at: url)
        }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let emptyURL = directory.appendingPathComponent("empty.wav")
        let empty = try RecordingSink(format: format, url: emptyURL, levels: { _ in })
        precondition(empty.finish() == nil)
        precondition(!FileManager.default.fileExists(atPath: emptyURL.path))
        print("PASS: buffer ownership, conversion duration, file finalization, late buffers, empty capture")
    }
}
