//
//  CMPlayerStats.swift
//  Quality
//
//  Created by Vincent Neo on 19/4/22.
//

import Foundation
import OSLog
import Sweep

struct CMPlayerStats {
    let sampleRate: Double // Hz
    let bitDepth: Int
    let date: Date
    let priority: Int
}

class CMPlayerParser {
    static func parseMusicConsoleLogs(_ entries: [SimpleConsole]) -> [CMPlayerStats] {
        let kTimeDifferenceAcceptance = 5.0 // seconds
        var lastDate: Date?
        var sampleRate: Double?
        var bitDepth: Int?
        
        var stats = [CMPlayerStats]()
        
        for entry in entries {
            // ignore useless log messages for faster switching
            if !entry.message.contains("audioCapabilities:") {
                continue
            }
            
            let date = entry.date
            let rawMessage = entry.message
            
            if let lastDate = lastDate, date.timeIntervalSince(lastDate) > kTimeDifferenceAcceptance {
                sampleRate = nil
                bitDepth = nil
            }
            
            if let subSampleRate = rawMessage.firstSubstring(between: "asbdSampleRate = ", and: " kHz") {
                let strSampleRate = String(subSampleRate)
                sampleRate = Double(strSampleRate)
            }
            
            if let subBitDepth = rawMessage.firstSubstring(between: "sdBitDepth = ", and: " bit") {
                let strBitDepth = String(subBitDepth)
                bitDepth = Int(strBitDepth)
            }
            else if rawMessage.contains("sdBitRate") { // lossy
                bitDepth = 16
            }
            
            if let sr = sampleRate,
               let bd = bitDepth {
                let stat = CMPlayerStats(sampleRate: sr * 1000, bitDepth: bd, date: date, priority: 1)
                stats.append(stat)
                sampleRate = nil
                bitDepth = nil
                print("detected stat \(stat)")
                break
            }
            
            lastDate = date
            
        }
        return stats
    }
    
    static func parseCoreAudioConsoleLogs(_ entries: [SimpleConsole]) -> [CMPlayerStats] {
        let kTimeDifferenceAcceptance = 5.0 // seconds
        var lastDate: Date?
        var sampleRate: Double?
        var bitDepth: Int?
        
        var stats = [CMPlayerStats]()
        
        for entry in entries {
            let date = entry.date
            let rawMessage = entry.message

            if let lastDate = lastDate, date.timeIntervalSince(lastDate) > kTimeDifferenceAcceptance {
                sampleRate = nil
                bitDepth = nil
            }
            
            if rawMessage.contains("ACAppleLosslessDecoder.cpp") && rawMessage.contains("Input format:") {
                if let subSampleRate = rawMessage.firstSubstring(between: "ch, ", and: " Hz") {
                    let strSampleRate = String(subSampleRate).trimmingCharacters(in: .whitespacesAndNewlines)
                    sampleRate = Double(strSampleRate)
                }
                
                if let subBitDepth = rawMessage.firstSubstring(between: "from ", and: "-bit source") {
                    let strBitDepth = String(subBitDepth).trimmingCharacters(in: .whitespacesAndNewlines)
                    bitDepth = Int(strBitDepth)
                }
            }
            
            if let sr = sampleRate,
               let bd = bitDepth {
                let stat = CMPlayerStats(sampleRate: sr, bitDepth: bd, date: date, priority: 5)
                stats.append(stat)
                sampleRate = nil
                bitDepth = nil
                print("detected stat \(stat)")
                break
            }
            
            lastDate = date
            
        }
        return stats
    }
    
    static func parseCoreMediaConsoleLogs(_ entries: [SimpleConsole]) -> [CMPlayerStats] {
        let kTimeDifferenceAcceptance = 5.0 // seconds
        var lastDate: Date?
        var sampleRate: Double?
        let bitDepth = 24 // Core Media don't provide bit depth, but I am keeping this for now, since it seems to be the first to deliver accurate bitrate data, fairly consistently.
        
        var stats = [CMPlayerStats]()
        
        for entry in entries {
            let date = entry.date
            let rawMessage = entry.message
            
            if let lastDate = lastDate, date.timeIntervalSince(lastDate) > kTimeDifferenceAcceptance {
                sampleRate = nil
            }
            
            if rawMessage.contains("Creating AudioQueue") {
                if let subSampleRate = rawMessage.firstSubstring(between: "sampleRate:", and: .end) {
                    let strSampleRate = String(subSampleRate)
                    sampleRate = Double(strSampleRate)
                }
            }
            
            if let sr = sampleRate {
                let stat = CMPlayerStats(sampleRate: sr, bitDepth: bitDepth, date: date, priority: 2)
                stats.append(stat)
                sampleRate = nil
                print("detected stat \(stat)")
                break
            }
            
            lastDate = date
            
        }
        return stats
    }
}

class LogStreamListener {
    private var process: Process?
    private let outputQueue = DispatchQueue(label: "logStreamQueue", qos: .userInteractive)
    var onLogReceived: ((CMPlayerStats) -> Void)?
    
    func start() {
        outputQueue.async { [weak self] in
            guard let self = self else { return }
            self.stop()
            
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
            process.arguments = ["stream", "--predicate", "eventMessage contains \"ACAppleLosslessDecoder\"", "--info"]
            
            let pipe = Pipe()
            process.standardOutput = pipe
            
            let fileHandle = pipe.fileHandleForReading
            fileHandle.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                if let output = String(data: data, encoding: .utf8) {
                    let lines = output.components(separatedBy: "\n")
                    for line in lines {
                        if let stat = self?.parseLogStreamLine(line) {
                            self?.onLogReceived?(stat)
                        }
                    }
                }
            }
            
            self.process = process
            do {
                try process.run()
                print("[LogStreamListener] Background log stream started successfully.")
            } catch {
                print("[LogStreamListener] Failed to start log stream process: \(error)")
            }
        }
    }
    
    func stop() {
        if let process = self.process {
            if process.isRunning {
                process.terminate()
            }
            self.process = nil
        }
    }
    
    private func parseLogStreamLine(_ line: String) -> CMPlayerStats? {
        guard line.contains("ACAppleLosslessDecoder.cpp") && line.contains("Input format:") else { return nil }
        
        let parts = line.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let datePart = String(parts[0])
        let timePart = String(parts[1])
        
        let fullDateStr = "\(datePart) \(timePart.prefix(12))"
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        let date = formatter.date(from: fullDateStr) ?? Date()
        
        var sampleRate: Double?
        var bitDepth: Int?
        
        if let subSampleRate = line.firstSubstring(between: "ch, ", and: " Hz") {
            let strSampleRate = String(subSampleRate).trimmingCharacters(in: .whitespacesAndNewlines)
            sampleRate = Double(strSampleRate)
        }
        
        if let subBitDepth = line.firstSubstring(between: "from ", and: "-bit source") {
            let strBitDepth = String(subBitDepth).trimmingCharacters(in: .whitespacesAndNewlines)
            bitDepth = Int(strBitDepth)
        }
        
        if let sr = sampleRate, let bd = bitDepth {
            return CMPlayerStats(sampleRate: sr, bitDepth: bd, date: date, priority: 5)
        }
        return nil
    }
}
