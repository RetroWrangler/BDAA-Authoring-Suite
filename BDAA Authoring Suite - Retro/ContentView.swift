//
//  ContentView.swift
//  BDAA Authoring Suite
//
//  Created by Cory on 8/22/25.
//  Single-file demo UI for Blu-ray Audio authoring orchestration.
//  External tools required (user-provided):
//  - ffprobe  (for metadata)
//  - ffmpeg   (for LPCM conversion and black/custom image video generation)
//  - tsMuxer  (for Blu-ray BDMV folder creation)
//
//  Notes/limits:
//  - "Dolby Atmos" here means TrueHD+Atmos pass-through only (no encoding).
//  - "DTS-HD Master Audio" pass-through only (no encoding).
//  - LPCM path normalizes to a single Blu-ray-legal PCM format across tracks.
//  - We generate an H.264 High@4.1 yuv420p video (black or still image) to satisfy Blu-ray players.


import SwiftUI
import AppKit
import Foundation
import Combine
import AVFoundation
import CoreMedia

// MARK: - Color Palette (fixed, app-specific)
extension Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8)  & 0xFF) / 255.0
        let b = Double(hex         & 0xFF) / 255.0
        self = Color(red: r, green: g, blue: b, opacity: alpha)
    }
}

struct Palette {
    static let bg      = Color(hex: 0x0E1524)      // deep navy
    static let panel   = Color(hex: 0x121C2D)      // card/panel
    static let border  = Color(hex: 0x2B3A55, alpha: 0.6)
    static let text    = Color.white.opacity(0.92)
    static let subtext = Color.white.opacity(0.72)
    static let accent  = Color(hex: 0x3AA0F6)      // blue accent
}

// MARK: - Process environment helpers
struct ProcEnv {
    static func augmented() -> [String:String] {
        var env = ProcessInfo.processInfo.environment
        let extra = "/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        if let existing = env["PATH"], !existing.isEmpty {
            if !existing.contains("/opt/homebrew/bin") { env["PATH"] = existing + ":" + extra }
        } else {
            env["PATH"] = extra
        }
        return env
    }
}

// Path where we can drop self-installed tools
func appSupportBinURL() -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    return base.appendingPathComponent("BDAA-Authoring-Suite/bin")
}

// MARK: - Models

struct AudioItem: Identifiable, Hashable {
    let id = UUID()
    var url: URL
    var displayName: String
    var duration: Double? // seconds
    var sampleRate: Int?
    var bitsPerSample: Int?
    var channels: Int?
    var codecName: String?
}

enum OutputCodec: String, CaseIterable, Identifiable {
    case lpcm = "LPCM (PCM WAV)"
    case truehd_passthrough = "Dolby TrueHD / Atmos (pass-through)"
    case dtshd_passthrough = "DTS-HD MA (pass-through)"
    var id: String { rawValue }
}

enum LPCMFormat: String, CaseIterable, Identifiable {
    case format_24_48 = "24-bit/48kHz"
    case format_24_96 = "24-bit/96kHz"
    case format_24_192 = "24-bit/192kHz"
    var id: String { rawValue }
    
    var sampleRate: Int {
        switch self {
        case .format_24_48: return 48000
        case .format_24_96: return 96000
        case .format_24_192: return 192000
        }
    }
    
    var bitDepth: Int { 24 }
}

enum ImageMode: String, CaseIterable, Identifiable {
    case none = "No Image"
    case custom = "Custom Image"
    var id: String { rawValue }
}

enum TextColor: String, CaseIterable, Identifiable {
    case white, red, black, yellow, purple, green, cyan, blue, orange
    var id: String { rawValue }
    var ffmpeg: String { rawValue }
}

enum GlowColor: String, CaseIterable, Identifiable {
    case white, black
    var id: String { rawValue }
    var ffmpeg: String { rawValue }
}

enum ImportMode: String, CaseIterable, Identifiable {
    case audioFiles = "Audio files"
    var id: String { rawValue }
}

enum DiscCapacity: String, CaseIterable, Identifiable {
    case bd25 = "BD 25 (25 GB)"
    case bd50 = "BD DL (50 GB)"
    case bd100 = "BD XL (100 GB)"
    var id: String { rawValue }
    var bytes: UInt64 {
        switch self {
        case .bd25: return 25_000_000_000
        case .bd50: return 50_000_000_000
        case .bd100: return 100_000_000_000
        }
    }
}

// Advanced Mode enums
enum BackgroundType: String, CaseIterable, Identifiable {
    case solid = "Solid Color"
    case gradient = "Gradient"
    case image = "Image"
    var id: String { rawValue }
}

enum BorderColor: String, CaseIterable, Identifiable {
    case white = "White"
    case black = "Black"
    var id: String { rawValue }
    
    var nsColor: NSColor {
        switch self {
        case .white: return .white
        case .black: return .black
        }
    }
}

enum TextGlowColor: String, CaseIterable, Identifiable {
    case white = "White"
    case black = "Black"
    var id: String { rawValue }
    
    var nsColor: NSColor {
        switch self {
        case .white: return .white
        case .black: return .black
        }
    }
}

struct AudioMetadata {
    let title: String
    let artist: String
    let album: String
    let trackNumber: Int
    let duration: Double
}

// MARK: - ViewModel

final class AuthoringViewModel: ObservableObject {
    @Published var items: [AudioItem] = []
    @Published var selection = Set<AudioItem.ID>()

    @Published var outputCodec: OutputCodec = .lpcm
    @Published var lpcmFormat: LPCMFormat = .format_24_48
    @Published var videoFPS: String = "23.976"
    @Published var videoResolution: String = "1920x1080"

    // Visuals
    // Removed old Simple Mode properties

    // Input mode (removed container mode)
    @Published var importMode: ImportMode = .audioFiles
    // MKV-related (inactive; kept for compile compatibility)
    @Published var mkvPath: String = ""
    @Published var preserveMKVVideo: Bool = true
    @Published var forceReencodeVideo: Bool = false
    @Published var mkvStreamInfo: String = ""
    @Published var useDemuxedVideo: Bool = true
    @Published var dumpMetaToLog: Bool = false

    // Tools
    @Published var ffprobePath: String = "/Users/cory/bin/ffprobe"
    @Published var ffmpegPath: String = "/Users/cory/bin/ffmpeg"
    @Published var tsMuxerPath: String = "/Users/cory/bin/tsMuxeR"

    // Output / status
    @Published var outputDirectory: URL? = nil
    @Published var logText: String = ""
    @Published var isWorking: Bool = false

    @Published var showDepsSheet: Bool = false
    @Published var brewLog: String = ""

    // UI: log visibility
    @Published var showLog: Bool = false

    // Cancellation management
    @Published private(set) var cancelRequested: Bool = false
    let killer = ProcessKiller()

    // Disc capacity target
    @Published var targetDisc: DiscCapacity = .bd25

    // Live estimate of final project size
    @Published var estimatedSizeBytes: UInt64 = 0

    // Video generation properties  
    @Published var useCustomVideo: Bool = true  // Toggle between custom video and black screen
    @Published var coverArtPath: URL?
    
    // Video customization
    @Published var customArtist: String = ""
    @Published var customAlbum: String = ""
    @Published var showArtist: Bool = false
    @Published var showAlbum: Bool = false
    @Published var backgroundType: BackgroundType = .solid
    @Published var solidColor: NSColor = .black
    @Published var gradientStartColor: NSColor = .black
    @Published var gradientEndColor: NSColor = .gray
    @Published var backgroundImagePath: URL?
    @Published var showBorder: Bool = false
    @Published var borderColor: BorderColor = .white
    @Published var trackTitleColor: NSColor = .white
    @Published var enableTextGlow: Bool = false
    @Published var textGlowColor: TextGlowColor = .white
    @Published var textGlowIntensity: Double = 5.0

    func cancelBuild() {
        guard isWorking else { return }
        cancelRequested = true
        appendLog("⚠️ Cancel requested; stopping…")
        DispatchQueue.main.async {
            self.killer.killAll()
        }
    }

    // Progress tracking
    @Published var progress: Double = 0.0   // 0.0 ... 1.0
    @Published var statusText: String = ""
    
    func setProgress(_ value: Double, status: String? = nil) {
        DispatchQueue.main.async {
            self.progress = max(0, min(1, value))
            if let s = status { self.statusText = s }
        }
    }

    // Derived
    var totalDuration: Double { items.compactMap { $0.duration }.reduce(0, +) }

    // MARK: - Logging
    func appendLog(_ s: String) {
        DispatchQueue.main.async {
            self.logText.append(s + "\n")
        }
    }

    // MARK: - File Import
    func addFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        // Allow common audio types - using file extensions for macOS 11.5 compatibility
        panel.allowedFileTypes = ["wav", "flac", "aiff", "aif", "m4a", "mp3", "thd", "truehd", "dtshd", "dts"]
        panel.message = "Choose audio files (FLAC/ALAC/WAV/AIFF/TrueHD/DTS-HD)."
        if panel.runModal() == .OK {
            for url in panel.urls {
                DispatchQueue.global(qos: .userInitiated).async {
                    Task {
                        await self.probeAndAdd(url: url)
                    }
                }
            }
        }
    }

    

    func removeSelected() {
        items.removeAll { selection.contains($0.id) }
        selection.removeAll()
    }

    func moveUp() {
        guard let id = selection.first, let idx = items.firstIndex(where: { $0.id == id }), idx > 0 else { return }
        items.swapAt(idx, idx - 1)
    }

    func moveDown() {
        guard let id = selection.first, let idx = items.firstIndex(where: { $0.id == id }), idx < items.count - 1 else { return }
        items.swapAt(idx, idx + 1)
    }

    /// Sort items alphanumerically by filename (without extension), using natural order (01 < 2 < 10)
    func sortAlphaNumericAscending() {
        items.sort { lhs, rhs in
            let l = lhs.url.deletingPathExtension().lastPathComponent
            let r = rhs.url.deletingPathExtension().lastPathComponent
            return l.localizedStandardCompare(r) == .orderedAscending
        }
    }

    // MARK: - Advanced Mode Functions
    func selectCoverArt() {
        let panel = NSOpenPanel()
        panel.title = "Select Album Cover Art"
        panel.allowsMultipleSelection = false
        panel.allowedFileTypes = ["png", "jpg", "jpeg", "tiff", "bmp", "gif"]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        
        if panel.runModal() == .OK {
            coverArtPath = panel.url
        }
    }
    
    func selectBackgroundImage() {
        let panel = NSOpenPanel()
        panel.title = "Select Background Image"
        panel.allowsMultipleSelection = false
        panel.allowedFileTypes = ["png", "jpg", "jpeg", "tiff", "bmp", "gif"]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        
        if panel.runModal() == .OK {
            backgroundImagePath = panel.url
        }
    }

    // MARK: - Probing
    func probeAndAdd(url: URL) async {
        // Strip extension for the display name
        let baseName = url.deletingPathExtension().lastPathComponent
        let initialItem = AudioItem(url: url, displayName: baseName, duration: nil, sampleRate: nil, bitsPerSample: nil, channels: nil, codecName: nil)
        do {
            let info = try await FFProbe(path: ffprobePath).probeAudio(url: url)
            let finalItem = AudioItem(
                url: url,
                displayName: baseName,
                duration: info.duration,
                sampleRate: info.sampleRate,
                bitsPerSample: info.bitsPerSample,
                channels: info.channels,
                codecName: info.codecName
            )
            DispatchQueue.main.async {
                self.items.append(finalItem)
                self.appendLog("Probed: \(finalItem.displayName) — sr=\(finalItem.sampleRate ?? 0) Hz, \(finalItem.bitsPerSample ?? 0)-bit, ch=\(finalItem.channels ?? 0), codec=\(finalItem.codecName ?? "?")")
            }
        } catch {
            DispatchQueue.main.async {
                self.appendLog("ffprobe failed for \(url.lastPathComponent): \(error.localizedDescription)")
                self.items.append(initialItem)
            }
        }
    }

    // Prefer a tool path: user field → candidates
    func resolveToolPath(preferred: String, candidates: [String]) -> String? {
        let fm = FileManager.default
        var paths = [preferred]
        paths.append(contentsOf: candidates)
        for p in paths {
            if p.isEmpty { continue }
            let test = p
            if test.contains("tsmuxer") == false && test.lowercased().hasSuffix("tsmuxer") {
                // also try capitalized variant some builds use
                let alt = test.replacingOccurrences(of: "tsmuxer", with: "tsMuxeR")
                if FileManager.default.isExecutableFile(atPath: alt) { return alt }
            }
            if fm.isExecutableFile(atPath: test) { return test }
        }
        return nil
    }

    // Expand ~
    func expandPath(_ p: String) -> String {
        var s = p
        if s.hasPrefix("~/") {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            s = home + String(s.dropFirst(1))
        }
        return s
    }

    // MARK: - Advanced Mode Video Creation
    func extractMetadata(from url: URL) async -> AudioMetadata {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let asset = AVAsset(url: url)
                
                var title = url.deletingPathExtension().lastPathComponent
                var artist = "Unknown Artist"
                var album = "Unknown Album"
                var trackNumber = 1
                var duration = 0.0
                
                // Get duration using macOS 11.5 compatible API
                duration = CMTimeGetSeconds(asset.duration)
                
                // Get metadata using older API compatible with macOS 11.5
                let metadata = asset.metadata
                for item in metadata {
                    // Try common key first
                    if let key = item.commonKey?.rawValue {
                        switch key {
                        case "title":
                            if let value = item.stringValue {
                                title = value
                            }
                        case "artist":
                            if let value = item.stringValue {
                                artist = value
                            }
                        case "albumName":
                            if let value = item.stringValue {
                                album = value
                            }
                        case "trackNumber":
                            if let value = item.stringValue, let trackNum = Int(value) {
                                trackNumber = trackNum
                            }
                        default: break
                        }
                    }
                    
                    // Also try identifier-based keys for FLAC files
                    if let identifier = item.identifier?.rawValue, let value = item.stringValue {
                        switch identifier.lowercased() {
                        case "title", "tit2":
                            title = value
                        case "artist", "tpe1":
                            artist = value
                        case "album", "talb", "albumtitle":
                            album = value
                        case "tracknumber", "trck":
                            if let trackNum = Int(value.components(separatedBy: "/").first ?? value) {
                                trackNumber = trackNum
                            }
                        default: break
                        }
                    }
                }
                
                let result = AudioMetadata(
                    title: title,
                    artist: artist,
                    album: album,
                    trackNumber: trackNumber,
                    duration: duration
                )
                
                DispatchQueue.main.async {
                    continuation.resume(returning: result)
                }
            }
        }
    }
    
    func createVideoFrame(coverArt: URL, trackTitle: String, trackNumber: Int, artist: String, album: String) -> NSImage? {
        let frameSize = NSSize(width: 1920, height: 1080)
        let image = NSImage(size: frameSize)
        
        image.lockFocus()
        defer { image.unlockFocus() }
        
        // Draw background based on type
        let backgroundRect = NSRect(origin: .zero, size: frameSize)
        
        if backgroundType == .solid {
            // Solid color background
            solidColor.setFill()
            backgroundRect.fill()
        } else if backgroundType == .gradient {
            // Gradient background
            let gradient = NSGradient(starting: gradientStartColor, ending: gradientEndColor)
            gradient?.draw(in: backgroundRect, angle: -90) // Top to bottom gradient
        } else if backgroundType == .image, let imagePath = backgroundImagePath {
            // Image background
            if let backgroundImage = NSImage(contentsOf: imagePath) {
                // Scale to fill the entire background while maintaining aspect ratio
                let imageSize = backgroundImage.size
                let scaleX = frameSize.width / imageSize.width
                let scaleY = frameSize.height / imageSize.height
                let scale = max(scaleX, scaleY) // Scale to fill (crop if needed)
                
                let scaledWidth = imageSize.width * scale
                let scaledHeight = imageSize.height * scale
                
                // Center the image
                let drawRect = NSRect(
                    x: (frameSize.width - scaledWidth) / 2,
                    y: (frameSize.height - scaledHeight) / 2,
                    width: scaledWidth,
                    height: scaledHeight
                )
                
                backgroundImage.draw(in: drawRect)
            } else {
                // Fallback to black if image fails to load
                NSColor.black.setFill()
                backgroundRect.fill()
            }
        }
        
        // Draw small cover art on left side
        if let coverImage = NSImage(contentsOf: coverArt) {
            let borderWidth: CGFloat = showBorder ? 8 : 0
            let coverSize: CGFloat = min(frameSize.height - 200, frameSize.width / 2 - 200)
            let coverRect = NSRect(
                x: (frameSize.width / 2 - coverSize) / 2,
                y: (frameSize.height - coverSize) / 2,
                width: coverSize,
                height: coverSize
            )
            
            // Draw border if enabled
            if showBorder {
                let borderRect = NSRect(
                    x: coverRect.origin.x - borderWidth,
                    y: coverRect.origin.y - borderWidth,
                    width: coverRect.width + (borderWidth * 2),
                    height: coverRect.height + (borderWidth * 2)
                )
                borderColor.nsColor.setFill()
                borderRect.fill()
            }
            
            coverImage.draw(in: coverRect)
        }
        
        // Draw text on right side for cover art mode
        let textStartX: CGFloat = frameSize.width / 2 + 50
        let textWidth: CGFloat = frameSize.width / 2 - 100
        
        // Track title with optional glow
        let trackText = trackTitle
        let titleFont = NSFont.systemFont(ofSize: 32, weight: .bold)
        let titleSize = trackText.size(withAttributes: [.font: titleFont])
        let titleRect = NSRect(
            x: textStartX,
            y: frameSize.height / 2 - 50,
            width: textWidth,
            height: titleSize.height
        )
        
        // Draw glow effect if enabled
        if enableTextGlow {
            let glowColor = textGlowColor.nsColor
            let glowRadius = CGFloat(textGlowIntensity)
            
            // Create multiple passes for stronger glow
            for offset in stride(from: -glowRadius, through: glowRadius, by: 0.5) {
                for yOffset in stride(from: -glowRadius, through: glowRadius, by: 0.5) {
                    let glowRect = NSRect(
                        x: titleRect.origin.x + offset,
                        y: titleRect.origin.y + yOffset,
                        width: titleRect.width,
                        height: titleRect.height
                    )
                    
                    let glowAttributes: [NSAttributedString.Key: Any] = [
                        .font: titleFont,
                        .foregroundColor: glowColor.withAlphaComponent(0.3)
                    ]
                    
                    trackText.draw(in: glowRect, withAttributes: glowAttributes)
                }
            }
        }
        
        // Draw main text on top
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: titleFont,
            .foregroundColor: trackTitleColor
        ]
        trackText.draw(in: titleRect, withAttributes: titleAttributes)
        
        // Artist (only if enabled)
        var currentY = frameSize.height / 2 - 120
        if showArtist && !artist.isEmpty {
            let artistAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 24),
                .foregroundColor: NSColor.lightGray
            ]
            
            let artistRect = NSRect(
                x: textStartX,
                y: currentY,
                width: textWidth,
                height: 40
            )
            artist.draw(in: artistRect, withAttributes: artistAttributes)
            currentY -= 50
        }
        
        // Album (only if enabled)
        if showAlbum && !album.isEmpty {
            let albumAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 20),
                .foregroundColor: NSColor.gray
            ]
            
            let albumRect = NSRect(
                x: textStartX,
                y: currentY,
                width: textWidth,
                height: 30
            )
            album.draw(in: albumRect, withAttributes: albumAttributes)
        }
        
        return image
    }
    
    private func generateAdvancedVideo(
        prepared: PreparedAudioResult,
        vmaker: VideoMaker,
        workDir: URL,
        fps: String,
        resolution: String
    ) async throws -> URL {
        var videoSegments: [URL] = []
        var currentTime: Double = 0
        
        // Create individual video segments for each track
        for (index, duration) in prepared.segmentDurations.enumerated() {
            if cancelRequested { throw AuthorError.cancelled }
            
            let item = index < items.count ? items[index] : nil
            let metadata = item != nil ? await extractMetadata(from: item!.url) : 
                AudioMetadata(title: "Track \(index + 1)", artist: "", album: "", trackNumber: index + 1, duration: duration)
            
            // Update progress
            let progressBase = 0.55
            let progressSpan = 0.25
            let segmentProgress = Double(index) / Double(prepared.segmentDurations.count)
            setProgress(progressBase + (progressSpan * segmentProgress), 
                       status: "Generating video for track \(index + 1)/\(prepared.segmentDurations.count)...")
            
            // Create frame image using our advanced video frame function
            appendLog("🎨 Creating frame for: \(metadata.title)")
            appendLog("   Artist: \(showArtist ? (customArtist.isEmpty ? metadata.artist : customArtist) : "(hidden)")")
            appendLog("   Album: \(showAlbum ? (customAlbum.isEmpty ? metadata.album : customAlbum) : "(hidden)")")
            appendLog("   Cover art: \(coverArtPath?.path ?? "(none)")")
            
            let frameImage = createVideoFrame(
                coverArt: coverArtPath ?? URL(fileURLWithPath: ""),
                trackTitle: metadata.title,
                trackNumber: metadata.trackNumber,
                artist: showArtist ? (customArtist.isEmpty ? metadata.artist : customArtist) : "",
                album: showAlbum ? (customAlbum.isEmpty ? metadata.album : customAlbum) : ""
            )
            
            // Save frame as temporary PNG
            let frameFile = workDir.appendingPathComponent("frame_\(index).png")
            guard let frameImage = frameImage,
                  let tiffData = frameImage.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiffData),
                  let pngData = bitmap.representation(using: NSBitmapImageRep.FileType.png, properties: [:]) else {
                throw AuthorError.custom("Failed to create frame image for track \(index + 1)")
            }
            
            try pngData.write(to: frameFile)
            
            // Update progress before video generation
            setProgress(progressBase + (progressSpan * (segmentProgress + 0.3/Double(prepared.segmentDurations.count))), 
                       status: "Rendering video for track \(index + 1)/\(prepared.segmentDurations.count)...")
            
            // Generate video segment from this frame
            let segmentVideo = try await vmaker.makeStillVideo(
                from: frameFile,
                duration: duration,
                fps: fps,
                resolution: resolution,
                overlays: [], // No overlays needed as text is rendered in image
                fontColor: "white",
                fontSize: 42,
                glowEnabled: false,
                glowColor: "black",
                glowIntensity: 0,
                outDir: workDir
            )
            
            videoSegments.append(segmentVideo)
            currentTime += duration
            
            // Update progress after video generation completes
            setProgress(progressBase + (progressSpan * (Double(index + 1) / Double(prepared.segmentDurations.count))), 
                       status: "Completed track \(index + 1)/\(prepared.segmentDurations.count)")
            
            // Clean up temporary frame file
            try? FileManager.default.removeItem(at: frameFile)
        }
        
        // Concatenate all video segments into final video
        setProgress(0.80, status: "Merging video segments...")
        let finalVideo = workDir.appendingPathComponent("advanced_final.mp4")
        
        // Create concat file for FFmpeg
        let concatFile = workDir.appendingPathComponent("concat_list.txt")
        let concatContent = videoSegments.map { "file '\($0.path)'" }.joined(separator: "\n")
        try concatContent.write(to: concatFile, atomically: true, encoding: .utf8)
        
        // Use FFmpeg to concatenate
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = [
            "-f", "concat",
            "-safe", "0",
            "-i", concatFile.path,
            "-c", "copy",
            "-y",
            finalVideo.path
        ]
        process.environment = ProcEnv.augmented()
        
        try process.run()
        process.waitUntilExit()
        
        guard process.terminationStatus == 0 else {
            throw AuthorError.custom("FFmpeg concatenation failed")
        }
        
        // Clean up segment files and concat file
        for segment in videoSegments {
            try? FileManager.default.removeItem(at: segment)
        }
        try? FileManager.default.removeItem(at: concatFile)
        
        return finalVideo
    }

    // MARK: - Build Blu-ray
    func buildBluRayFolder() {
        guard !isWorking else { return }
        guard let outDir = pickOrCreateOutputDir() else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            Task {
                await self.performBuild(outDir: outDir)
            }
        }
    }
    
    private func performBuild(outDir: URL) async {
        DispatchQueue.main.async {
            self.isWorking = true
            self.cancelRequested = false
            self.setProgress(0.02, status: "Starting build…")
        }
        
        defer {
            DispatchQueue.main.async {
                self.isWorking = false
            }
        }
        
        do {
            appendLog("Starting build…")

            // Resolve tool paths dynamically
            let appSupportBin = appSupportBinURL().path
            let bundleBin = Bundle.main.resourcePath.map { $0 + "/bin" } ?? ""

            let tsApp1 = "/Applications/tsMuxeR.app/Contents/MacOS/tsMuxeR"
            let tsApp2 = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/tsMuxeR.app/Contents/MacOS/tsMuxeR").path

            let ffmpegCandidates = [
                expandPath(self.ffmpegPath),
                "/Users/cory/bin/ffmpeg",
                expandPath("~/bin/ffmpeg"),
                "/opt/homebrew/bin/ffmpeg",
                "/usr/local/bin/ffmpeg",
                appSupportBin + "/ffmpeg",
                bundleBin + "/ffmpeg",
                "ffmpeg"
            ]
            let ffprobeCandidates = [
                expandPath(self.ffprobePath),
                "/Users/cory/bin/ffprobe",
                expandPath("~/bin/ffprobe"),
                "/opt/homebrew/bin/ffprobe",
                "/usr/local/bin/ffprobe",
                appSupportBin + "/ffprobe",
                bundleBin + "/ffprobe",
                "ffprobe"
            ]
            let tsmuxerCandidates = [
                expandPath(self.tsMuxerPath),
                "/Users/cory/bin/tsMuxeR",
                expandPath("~/bin/tsMuxeR"),
                tsApp1,
                tsApp2,
                "/usr/local/bin/tsmuxer",
                "/opt/homebrew/bin/tsmuxer",
                appSupportBin + "/tsmuxer",
                bundleBin + "/tsMuxeR",
                "tsmuxer",
                "tsMuxeR"
            ]

            self.setProgress(0.08, status: "Validating tools…")

            if let p = resolveToolPath(preferred: self.ffmpegPath, candidates: ffmpegCandidates) { 
                DispatchQueue.main.async { self.ffmpegPath = p }
            } else { 
                throw AuthorError.toolMissing(name: "ffmpeg") 
            }
            if let p = resolveToolPath(preferred: self.ffprobePath, candidates: ffprobeCandidates) { 
                DispatchQueue.main.async { self.ffprobePath = p }
            } else { 
                throw AuthorError.toolMissing(name: "ffprobe") 
            }
            if let p = resolveToolPath(preferred: self.tsMuxerPath, candidates: tsmuxerCandidates) { 
                DispatchQueue.main.async { self.tsMuxerPath = p }
            } else { 
                throw AuthorError.toolMissing(name: "tsMuxeR") 
            }

            func execState(_ path: String) -> String {
                let fm = FileManager.default
                let exists = fm.fileExists(atPath: path)
                let exec = fm.isExecutableFile(atPath: path)
                return "[exists=\(exists) exec=\(exec)]"
            }
            appendLog("Using tools:\n  ffmpeg: \(self.ffmpegPath) \(execState(self.ffmpegPath))\n  ffprobe: \(self.ffprobePath) \(execState(self.ffprobePath))\n  tsMuxer: \(self.tsMuxerPath) \(execState(self.tsMuxerPath))")

            self.setProgress(0.12, status: "Preparing workspace…")

            // Validate versions
            try ToolChecker.check(path: self.ffmpegPath, name: "ffmpeg")
            try ToolChecker.check(path: self.ffprobePath, name: "ffprobe")
            try ToolChecker.check(path: self.tsMuxerPath, name: "tsMuxeR")

            // 2) Prepare temp workspace
            let work = try Workspace()
            appendLog("Workspace: \(work.root.path)")

            // Initial rough size estimate before rendering
            DispatchQueue.main.async {
                self.estimatedSizeBytes = self.roughEstimateSizeBytes()
            }

            self.setProgress(0.18, status: "Preparing audio…")
            if self.cancelRequested { throw AuthorError.cancelled }

            // 3) Prepare audio according to outputCodec
            let prepared = try await prepareAudio(in: work) { i, n in
                let base = 0.18
                let span = 0.37 // progress from 18% to 55%
                let frac = Double(i) / Double(max(n, 1))
                self.setProgress(base + span * frac, status: "Preparing audio (\(i)/\(n))…")
            }
            if self.cancelRequested { throw AuthorError.cancelled }

            // Update estimate after audio is prepared (use actual WAV or passthrough size)
            do {
                let aBytes = try Self.fileSizeBytes(at: prepared.audioPath)
                // Add a conservative video placeholder until we generate it
                let vEst = self.videoEstimateBytes(forDuration: prepared.totalDuration)
                DispatchQueue.main.async {
                    self.estimatedSizeBytes = UInt64(Double(aBytes + vEst))
                }
            } catch { /* ignore estimate error */ }

            self.setProgress(0.55, status: "Generating video…")
            if self.cancelRequested { throw AuthorError.cancelled }

            // 4) Generate video for audio-only mode
            let dur = prepared.totalDuration
            let fps = videoFPS
            let res = videoResolution

            // Removed overlay functionality - now handled in custom frames

            let vmaker = VideoMaker(ffmpeg: ffmpegPath, log: appendLog, killer: self.killer)
            
            // Generate video based on user preference
            let h264: URL
            if useCustomVideo {
                appendLog("🎨 Generating custom video frames...")
                h264 = try await generateAdvancedVideo(
                    prepared: prepared,
                    vmaker: vmaker,
                    workDir: work.root,
                    fps: fps,
                    resolution: res
                )
                appendLog("Custom video ready: \(h264.lastPathComponent)")
            } else {
                appendLog("🖤 Generating black video...")
                h264 = try await vmaker.makeBlackVideo(
                    duration: dur,
                    fps: fps,
                    resolution: res,
                    overlays: [],
                    fontColor: "white",
                    fontSize: 24,
                    glowEnabled: false,
                    glowColor: "black",
                    glowIntensity: 0,
                    outDir: work.root
                )
                appendLog("Black video ready: \(h264.lastPathComponent)")
            }
            if self.cancelRequested { throw AuthorError.cancelled }

            // Refine estimate with actual video file size
            do {
                let aBytes = try Self.fileSizeBytes(at: prepared.audioPath)
                let vBytes = try Self.fileSizeBytes(at: h264)
                // Add small mux/container overhead
                let sum = Double(aBytes + vBytes) * 1.06
                DispatchQueue.main.async {
                    self.estimatedSizeBytes = UInt64(sum)
                }
            } catch { /* ignore estimate error */ }

            self.setProgress(0.70, status: "Writing chapters…")
            if self.cancelRequested { throw AuthorError.cancelled }

            // 5) Build chapters file
            let chaptersURL = try ChapterWriter().writeChapters(durations: prepared.segmentDurations, outDir: work.root)
            appendLog("Chapters file: \(chaptersURL.lastPathComponent)")

            self.setProgress(0.78, status: "Creating meta…")
            if self.cancelRequested { throw AuthorError.cancelled }

            // 6) Create tsMuxer meta file (uses --custom-chapters=…)
            let metaURL = try TSMetaWriter().writeMeta(videoPath: h264, audioPath: prepared.audioPath, audioType: prepared.tsmuxerAudioType, fps: fps, chaptersPath: chaptersURL)
            appendLog("Meta file: \(metaURL.lastPathComponent)")

            self.setProgress(0.82, status: "Multiplexing (tsMuxeR)…")
            if self.cancelRequested { throw AuthorError.cancelled }

            // 7) Run tsMuxer to build BDMV
            let outputBDDir = outDir.appendingPathComponent("BDMV_OUT_\(DateFormatter.compactTimestamp())")
            try FileManager.default.createDirectory(at: outputBDDir, withIntermediateDirectories: true)
            let muxer = TSMuxer(path: tsMuxerPath, log: appendLog, killer: self.killer)
            try await muxer.buildBluRay(metaPath: metaURL, outputDir: outputBDDir)

            self.setProgress(0.96, status: "Finalizing folder…")
            if self.cancelRequested { throw AuthorError.cancelled }

            // 8) Ensure CERTIFICATE folder exists
            let certDir = outputBDDir.appendingPathComponent("CERTIFICATE")
            if !FileManager.default.fileExists(atPath: certDir.path) {
                try FileManager.default.createDirectory(at: certDir, withIntermediateDirectories: true)
            }

            // Final size after muxing
            do { 
                DispatchQueue.main.async {
                    self.estimatedSizeBytes = (try? Self.directorySizeBytes(at: outputBDDir)) ?? 0
                }
            }

            self.setProgress(1.0, status: "Done")
            appendLog("✅ Blu-ray folder created: \(outputBDDir.path)")
        } catch {
            self.setProgress(0.0, status: "Failed")
            appendLog("❌ Build failed: \(error.localizedDescription)")
        }
    }

    func burnBluRay() {
        guard !isWorking else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose the Blu-ray folder (must contain BDMV and CERTIFICATE). An ISO will be created and burned."
        if panel.runModal() != .OK { return }
        let folderURL = panel.urls[0]
        DispatchQueue.global(qos: .userInitiated).async {
            Task {
                await self.performBurn(folderURL: folderURL)
            }
        }
    }
    
    private func performBurn(folderURL: URL) async {
        DispatchQueue.main.async {
            self.isWorking = true
            self.setProgress(0.05, status: "Preflight…")
        }
        
        defer {
            DispatchQueue.main.async {
                self.isWorking = false
            }
        }
        
        do {
            // Capacity preflight against selected target
            let size = try Self.directorySizeBytes(at: folderURL)
            if size > self.targetDisc.bytes {
                let overGB = String(format: "%.2f", Double(size) / 1_000_000_000.0)
                self.appendLog("❌ Folder size (\(overGB) GB) exceeds target disc \(self.targetDisc.rawValue).")
                self.setProgress(0.0, status: "Too large for target disc")
                return
            }
            self.setProgress(0.10, status: "Creating ISO…")
            try DiscBurner(log: appendLog).burnBDMV(from: folderURL)
            self.setProgress(1.0, status: "Burn command sent")
            appendLog("🔥 Burn started (ISO created and sent to drive).")
        } catch {
            self.setProgress(0.0, status: "Failed")
            appendLog("❌ Burn failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers
    static func directorySizeBytes(at url: URL) throws -> UInt64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: [.skipsHiddenFiles]) else {
            return 0
        }
        var total: UInt64 = 0
        for case let fileURL as URL in enumerator {
            let res = try fileURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if res.isDirectory == true { continue }
            if let s = res.fileSize { total += UInt64(s) }
        }
        return total
    }

    static func fileSizeBytes(at url: URL) throws -> UInt64 {
        let vals = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        if vals.isDirectory == true { return 0 }
        return UInt64(vals.fileSize ?? 0)
    }

    // Rough size estimation based on current settings and inputs
    private func roughEstimateSizeBytes() -> UInt64 {
        let totalDur = totalDuration
        var audioBytes: Double = 0
        switch outputCodec {
        case .lpcm:
            // Mirror prepareAudio logic: choose target SR/bit-depth/channels
            let inputSRs = items.compactMap { $0.sampleRate }
            let allAre96k = !inputSRs.isEmpty && inputSRs.allSatisfy { $0 == 96000 }
            let allAre192k = !inputSRs.isEmpty && inputSRs.allSatisfy { $0 == 192000 }
            let targetSR: Int = allAre192k ? 192000 : (allAre96k ? 96000 : 48000)
            let maxBD = (items.compactMap { $0.bitsPerSample }.max() ?? 16)
            let bitDepth = maxBD >= 24 ? 24 : 16
            let channels = items.compactMap { $0.channels }.max() ?? 2
            audioBytes = Double(targetSR * channels) * (Double(bitDepth) / 8.0) * totalDur
        case .truehd_passthrough, .dtshd_passthrough:
            // Approximate using source file sizes when available
            let sum: UInt64 = items.reduce(0) { acc, it in
                let s: UInt64 = (try? Self.fileSizeBytes(at: it.url)) ?? 0
                return acc + s
            }
            audioBytes = Double(sum)
        }
        // Very conservative video estimate for generated black/still H.264
        let videoBytes = videoEstimateBytes(forDuration: totalDur)
        let sum = (audioBytes + Double(videoBytes)) * 1.06 // overhead
        return UInt64(max(0, sum))
    }

    // Estimate video size for black/still H.264 at a tiny bitrate envelope
    private func videoEstimateBytes(forDuration seconds: Double) -> UInt64 {
        // Assume ~0.5 Mbps for very low-complexity content
        let mbps = 0.5
        let bytesPerSec = (mbps * 1_000_000.0) / 8.0
        return UInt64(bytesPerSec * seconds)
    }
    private func pickOrCreateOutputDir() -> URL? {
        if let out = outputDirectory { return out }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Select or create an output directory for the Blu-ray folder."
        if panel.runModal() == .OK { self.outputDirectory = panel.urls.first; return panel.urls.first }
        return nil
    }

    // Prepare audio according to chosen output mode; returns path to single prepared audio and segment durations
    private func prepareAudio(in work: Workspace, progress: @escaping (_ current: Int, _ total: Int) async -> Void) async throws -> PreparedAudioResult {
        guard !items.isEmpty else { throw AuthorError.noItems }

        switch outputCodec {
        case .lpcm:
            // Convert each track to WAV using the user-selected LPCM format
            let ff = FFmpeg(path: ffmpegPath, log: appendLog, killer: self.killer)
            
            // Use the selected LPCM format settings
            let targetSR = lpcmFormat.sampleRate
            let targetBitDepth = lpcmFormat.bitDepth
            let targetSampleFmt = PCMFormatter.ffmpegSampleFormat(forBitDepth: targetBitDepth)

            let targetCh = items.compactMap { $0.channels }.max() ?? 2
            appendLog("Using LPCM format: \(lpcmFormat.rawValue)")

            var outWavs: [URL] = []
            var durations: [Double] = []
            let totalCount = items.count
            var current = 0
            for item in items {
                let out = work.root.appendingPathComponent(item.url.deletingPathExtension().lastPathComponent + "_lpcm.wav")
                try await ff.convertToWavLPCM(input: item.url, output: out, sr: targetSR, sampleFmt: targetSampleFmt, channels: targetCh)
                current += 1
                await progress(current, totalCount)
                outWavs.append(out)
                durations.append(item.duration ?? 0)
            }
            // Concatenate WAVs (re-encode for uniform headers)
            let concatList = work.root.appendingPathComponent("concat.txt")
            let listText = outWavs.map { "file '\($0.path.replacingOccurrences(of: "'", with: "'\\''"))'" }.joined(separator: "\n")
            try listText.write(to: concatList, atomically: true, encoding: .utf8)
            let joinedWav = work.root.appendingPathComponent("program_lpcm.wav")
            try await ff.concatWavs(listFile: concatList, output: joinedWav, sr: targetSR, sampleFmt: targetSampleFmt, channels: targetCh)
            return PreparedAudioResult(audioPath: joinedWav, tsmuxerAudioType: .lpcm, segmentDurations: durations, totalDuration: durations.reduce(0, +))

        case .truehd_passthrough:
            guard items.count == 1 else { throw AuthorError.expectedSingleElementary }
            let item = items[0]
            // If already elementary .thd, pass through
            if item.url.pathExtension.lowercased() == "thd" || item.url.pathExtension.lowercased() == "truehd" {
                await progress(1, 1)
                return PreparedAudioResult(audioPath: item.url, tsmuxerAudioType: .truehd, segmentDurations: [item.duration ?? 0], totalDuration: item.duration ?? 0)
            }
            // If a container with TrueHD track, demux it
            if (item.codecName?.lowercased() == "truehd") {
                let ff = FFmpeg(path: ffmpegPath, log: appendLog, killer: self.killer)
                let out = work.root.appendingPathComponent(item.url.deletingPathExtension().lastPathComponent + ".thd")
                try await ff.demuxAudioCopy(input: item.url, streamIndex: 0, output: out)
                await progress(1, 1)
                return PreparedAudioResult(audioPath: out, tsmuxerAudioType: .truehd, segmentDurations: [item.duration ?? 0], totalDuration: item.duration ?? 0)
            }
            throw AuthorError.expectedTrueHD

        case .dtshd_passthrough:
            guard items.count == 1 else { throw AuthorError.expectedSingleElementary }
            let item = items[0]
            // If already elementary .dtshd, pass through
            if item.url.pathExtension.lowercased() == "dtshd" {
                await progress(1, 1)
                return PreparedAudioResult(audioPath: item.url, tsmuxerAudioType: .dtshd, segmentDurations: [item.duration ?? 0], totalDuration: item.duration ?? 0)
            }
            // If a container with DTS(-HD MA) track, demux it
            if (item.codecName?.lowercased().contains("dts") == true) {
                let ff = FFmpeg(path: ffmpegPath, log: appendLog, killer: self.killer)
                let out = work.root.appendingPathComponent(item.url.deletingPathExtension().lastPathComponent + ".dtshd")
                try await ff.demuxAudioCopy(input: item.url, streamIndex: 0, output: out)
                await progress(1, 1)
                return PreparedAudioResult(audioPath: out, tsmuxerAudioType: .dtshd, segmentDurations: [item.duration ?? 0], totalDuration: item.duration ?? 0)
            }
            throw AuthorError.expectedDTSHD
        }
    }

    private func tryPassthrough(type: TSMuxerAudioType) throws -> PreparedAudioResult {
        guard !items.isEmpty else { throw AuthorError.noItems }
        if items.count != 1 { throw AuthorError.expectedSingleElementary }
        let item = items[0]
        let ext = item.url.pathExtension.lowercased()
        if type == .truehd && !(ext == "thd" || ext == "truehd" || item.codecName?.lowercased() == "truehd") {
            throw AuthorError.expectedTrueHD
        }
        if type == .dtshd && !(ext == "dtshd" || item.codecName?.lowercased().contains("dts") == true) {
            throw AuthorError.expectedDTSHD
        }
        let duration = item.duration ?? 0
        return PreparedAudioResult(audioPath: item.url, tsmuxerAudioType: type, segmentDurations: [duration], totalDuration: duration)
    }
}

// MARK: - Core helpers

struct PreparedAudioResult {
    var audioPath: URL
    var tsmuxerAudioType: TSMuxerAudioType
    var segmentDurations: [Double]
    var totalDuration: Double
}

enum AuthorError: LocalizedError {
    case noItems
    case expectedSingleElementary
    case expectedTrueHD
    case expectedDTSHD
    case toolMissing(name: String)
    case cancelled
    case custom(String)

    var errorDescription: String? {
        switch self {
        case .noItems: return "No audio items in the list."
        case .expectedSingleElementary: return "Pass-through modes expect exactly one elementary stream file."
        case .expectedTrueHD: return "Expected a TrueHD (.thd/.truehd) input for Atmos/TrueHD pass-through."
        case .expectedDTSHD: return "Expected a DTS-HD MA (.dtshd) input for DTS pass-through."
        case .toolMissing(let name): return "Required tool not found: \(name)."
        case .cancelled: return "Operation cancelled by user."
        case .custom(let message): return message
        }
    }
}

final class ProcessKiller {
    private var procs: [Process] = []
    func register(_ p: Process) { procs.append(p) }
    func unregister(_ p: Process) { procs.removeAll { $0 === p } }
    func killAll() {
        for p in procs {
            if p.isRunning {
                p.terminate()
                p.interrupt()
            }
        }
        procs.removeAll()
    }
}

enum TSMuxerAudioType {
    case lpcm
    case truehd
    case dtshd

    var metaToken: String {
        switch self {
        case .lpcm:  return "A_LPCM"
        case .truehd:return "A_TRUEHD"
        case .dtshd: return "A_DTSHD"
        }
    }
}

enum PCMFormatter {
    static func ffmpegSampleFormat(forBitDepth bd: Int) -> String {
        if bd <= 16 { return "s16" }
        if bd <= 24 { return "s32" }
        return "s32"
    }
}

struct ToolChecker {
    static func check(path: String, name: String) throws {
        let fm = FileManager.default
        var execPath = path

        // If a .app bundle was provided, try common executable names inside
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: execPath, isDirectory: &isDir), isDir.boolValue, execPath.hasSuffix(".app") {
            let cand1 = execPath + "/Contents/MacOS/tsMuxeR"
            let cand2 = execPath + "/Contents/MacOS/tsmuxer"
            if fm.isExecutableFile(atPath: cand1) { execPath = cand1 }
            else if fm.fileExists(atPath: cand1) { execPath = cand1 }
            else if fm.isExecutableFile(atPath: cand2) { execPath = cand2 }
            else if fm.fileExists(atPath: cand2) { execPath = cand2 }
        }

        // If file exists but not executable, try to fix perms and remove quarantine
        if fm.fileExists(atPath: execPath) && !fm.isExecutableFile(atPath: execPath) {
            _ = try? setExecutable(executableAt: execPath)
            _ = try? removeQuarantine(at: execPath)
        }
        
        // Quick validation: if file exists and is executable, and it's our known good tsMuxeR, skip detailed validation
        if name.lowercased().contains("tsmuxer") && fm.isExecutableFile(atPath: execPath) {
            let fileSize = (try? fm.attributesOfItem(atPath: execPath)[.size] as? Int) ?? 0
            if fileSize > 1000000 { // Reasonable size check (> 1MB)
                return // Skip validation for known good binary
            }
        }

        // Prepare to run a lightweight command to verify
        let isTS = name.lowercased().contains("tsmuxer")
        let args: [String] = isTS ? [execPath] : [execPath, "-version"]
        let (status, out) = runSync(args: args)

        if isTS {
            // tsMuxeR is valid if it has any of these exit codes or mentions itself in output
            // Exit codes: 0=success, 1-2=normal, 4=no args (normal), 132=help flag, 15=terminated
            if status == 0 || status == 1 || status == 2 || status == 4 || status == 15 || status == 132 || 
               out.lowercased().contains("tsmuxer") || out.lowercased().contains("muxer") ||
               out.contains("Network Optix") || out.contains("Version") {
                return
            }
        } else {
            if status == 0 { return }
        }
        throw NSError(domain: "toolcheck", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "\(name) not runnable at \(execPath). Exit code: \(status). Output: \(out)"])
    }

    private static func setExecutable(executableAt path: String) throws {
        var attrs = try FileManager.default.attributesOfItem(atPath: path)
        attrs[.posixPermissions] = 0o755
        try FileManager.default.setAttributes(attrs, ofItemAtPath: path)
    }

    private static func removeQuarantine(at path: String) throws {
        let task = Process()
        task.environment = ProcEnv.augmented()
        task.launchPath = "/usr/bin/env"
        task.arguments = ["xattr", "-d", "com.apple.quarantine", path]
        try? task.run()
        task.waitUntilExit()
    }

    private static func runSync(args: [String]) -> (Int32, String) {
        let task = Process()
        task.environment = ProcEnv.augmented()
        task.launchPath = "/usr/bin/env"
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do { try task.run() } catch {
            return (127, "Failed to run: \(error.localizedDescription)")
        }
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: data, encoding: .utf8) ?? ""
        return (task.terminationStatus, out)
    }
}

final class Workspace {
    let root: URL
    init() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("BDAA_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.root = base
    }
    deinit {
        // Optional cleanup
        // try? FileManager.default.removeItem(at: root)
    }
}

// MARK: - ffprobe / ffmpeg wrappers

struct FFProbeInfo { let duration: Double; let sampleRate: Int; let bitsPerSample: Int; let channels: Int; let codecName: String }

struct FFProbe {
    let path: String
    func probeAudio(url: URL) async throws -> FFProbeInfo {
        let args = [path, "-v", "error",
                    "-show_entries", "stream=codec_name,channels,sample_rate,bits_per_raw_sample,bits_per_sample:format=duration",
                    "-select_streams", "a:0", "-of", "json", url.path]
        let data = try await runAndCapture(args: args)
        struct Root: Decodable { struct Stream: Decodable { let codec_name: String?; let channels: Int?; let sample_rate: String?; let bits_per_raw_sample: String?; let bits_per_sample: Int? }; let streams: [Stream]?; struct Format: Decodable { let duration: String? }; let format: Format? }
        let root = try JSONDecoder().decode(Root.self, from: data)
        let s = root.streams?.first
        let sr = Int(s?.sample_rate ?? "0") ?? 0
        let bprs = Int(s?.bits_per_raw_sample ?? "0") ?? 0
        let bps = s?.bits_per_sample ?? (bprs > 0 ? bprs : 0)
        let ch = s?.channels ?? 0
        let codec = s?.codec_name ?? "?"
        let dur = Double(root.format?.duration ?? "0") ?? 0
        return FFProbeInfo(duration: dur, sampleRate: sr, bitsPerSample: bps, channels: ch, codecName: codec)
    }

    private func runAndCapture(args: [String]) async throws -> Data {
        return try await withCheckedThrowingContinuation { cont in
            let task = Process()
            task.environment = ProcEnv.augmented()
            task.launchPath = "/usr/bin/env"
            task.arguments = args
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = pipe
            task.terminationHandler = { p in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if p.terminationStatus == 0 {
                    cont.resume(returning: data)
                } else {
                    let s = String(data: data, encoding: .utf8) ?? ""
                    cont.resume(throwing: NSError(domain: "ffprobe", code: Int(p.terminationStatus), userInfo: [NSLocalizedDescriptionKey: s.isEmpty ? "ffprobe failed" : s]))
                }
            }
            do { try task.run() } catch { cont.resume(throwing: error) }
        }
    }
}

struct Overlay { let start: Double; let end: Double; let text: String }

struct FFmpeg {
    let path: String
    let log: (String) -> Void
    weak var killer: ProcessKiller?

    private func resolveFontFile() -> String {
        let candidates = [
            "/System/Library/Fonts/Helvetica.ttc",
            "/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
            "/System/Library/Fonts/Supplemental/Arial.ttf",
            "/Library/Fonts/Arial.ttf",
            "/Library/Fonts/Helvetica.ttc"
        ]
        for c in candidates { if FileManager.default.fileExists(atPath: c) { return c } }
        return "/System/Library/Fonts/Helvetica.ttc"
    }

    private func escapeDrawtext(_ s: String) -> String {
        // Escape characters significant to drawtext: \ : ' %
        var out = s.replacingOccurrences(of: "\\", with: "\\\\")
        out = out.replacingOccurrences(of: ":", with: "\\:")
        out = out.replacingOccurrences(of: "'", with: "\\'")
        out = out.replacingOccurrences(of: "%", with: "%%")
        return out
    }

    private func buildDrawtextFilters(
        overlays: [Overlay],
        color: String,
        fontSize: Int,
        glowEnabled: Bool,
        glowColor: String,
        glowIntensity: Int
    ) -> String? {
        guard !overlays.isEmpty else { return nil }
        
        // Limit to maximum 500 overlays to handle very large albums
        let limitedOverlays = Array(overlays.prefix(500))
        
        let font = resolveFontFile()
        let bw = max(0, min(20, glowIntensity))
        let shadow = max(0, min(20, Int(ceil(Double(bw) / 2.0))))
        
        var result = ""
        for (index, ov) in limitedOverlays.enumerated() {
            let text = escapeDrawtext(ov.text)
            let startTime = String(format: "%.3f", ov.start)
            let endTime = String(format: "%.3f", ov.end)
            
            var filter = "drawtext=fontfile='\(font)':text='\(text)':fontcolor=\(color):fontsize=\(fontSize)"
            filter += ":x=w-tw-40:y=h-th-40"
            
            if glowEnabled {
                filter += ":bordercolor=\(glowColor):borderw=\(bw)"
                if shadow > 0 {
                    filter += ":shadowcolor=\(glowColor):shadowx=\(shadow):shadowy=\(shadow)"
                }
            }
            
            filter += ":enable=between(t\\,\(startTime)\\,\(endTime))"
            
            if index == 0 {
                result = filter
            } else {
                result += "," + filter
            }
        }
        return result
    }

    func convertToWavLPCM(input: URL, output: URL, sr: Int, sampleFmt: String, channels: Int) async throws {
        // For 24-bit LPCM, use packed format that tsMuxer expects
        let codecArg = sampleFmt == "s32" ? "pcm_s24le" : "pcm_\(sampleFmt)le"
        
        var args: [String]
        if sampleFmt == "s32" {
            // For 24-bit, don't specify -sample_fmt, let the codec handle it
            args = [path, "-y", "-i", input.path, "-vn", "-ac", "\(channels)", "-ar", "\(sr)", "-c:a", codecArg, output.path]
        } else {
            args = [path, "-y", "-i", input.path, "-vn", "-ac", "\(channels)", "-ar", "\(sr)", "-sample_fmt", sampleFmt, "-c:a", codecArg, output.path]
        }
        log("ffmpeg: \(args.joined(separator: " "))")
        try await run(args: args)
    }

    func concatWavs(listFile: URL, output: URL, sr: Int, sampleFmt: String, channels: Int) async throws {
        let codecArg = sampleFmt == "s32" ? "pcm_s24le" : "pcm_\(sampleFmt)le"
        
        var args: [String]
        if sampleFmt == "s32" {
            // For 24-bit, don't specify -sample_fmt, let the codec handle it
            args = [
                path, "-y",
                "-f", "concat", "-safe", "0",
                "-i", listFile.path,
                "-vn",
                "-ac", "\(channels)",
                "-ar", "\(sr)",
                "-c:a", codecArg,
                output.path
            ]
        } else {
            args = [
                path, "-y",
                "-f", "concat", "-safe", "0",
                "-i", listFile.path,
                "-vn",
                "-ac", "\(channels)",
                "-ar", "\(sr)",
                "-sample_fmt", sampleFmt,
                "-c:a", codecArg,
                output.path
            ]
        }
        log("ffmpeg: \(args.joined(separator: " "))")
        try await run(args: args)
    }

    func demuxAudioCopy(input: URL, streamIndex: Int, output: URL) async throws {
        let args: [String] = [
            path, "-y",
            "-i", input.path,
            "-map", "a:\(streamIndex)",
            "-c", "copy",
            output.path
        ]
        log("ffmpeg: \(args.joined(separator: " "))")
        try await run(args: args)
    }

    func makeBlackH264(
        duration: Double, fps: String, resolution: String,
        overlays: [Overlay], fontColor: String, fontSize: Int,
        glowEnabled: Bool, glowColor: String, glowIntensity: Int,
        out: URL
    ) async throws {
        let durStr = String(format: "%.3f", duration)
        var vf = "format=yuv420p"
        if let dt = buildDrawtextFilters(overlays: overlays, color: fontColor, fontSize: fontSize, glowEnabled: glowEnabled, glowColor: glowColor, glowIntensity: glowIntensity) {
            vf += "," + dt
        }
        log("Video filter string: \(vf)")
        let args: [String] = [
            path, "-y",
            "-f", "lavfi", "-i", "color=black:s=\(resolution):r=\(fps)",
            "-t", durStr,
            "-vf", vf,
            "-c:v", "libx264",
            "-pix_fmt", "yuv420p",
            "-profile:v", "high",
            "-level:v", "4.1",
            "-x264-params", "keyint=48:min-keyint=48:no-scenecut=1",
            "-an",
            "-f", "h264",
            out.path
        ]
        log("ffmpeg: \(args.joined(separator: " "))")
        try await run(args: args)
    }

    func makeStillH264(
        image: URL, duration: Double, fps: String, resolution: String,
        overlays: [Overlay], fontColor: String, fontSize: Int,
        glowEnabled: Bool, glowColor: String, glowIntensity: Int,
        out: URL
    ) async throws {
        let durStr = String(format: "%.3f", duration)
        let parts = resolution.lowercased().split(separator: "x")
        let w = parts.first.map(String.init) ?? "1920"
        let h = (parts.count > 1 ? String(parts[1]) : "1080")
        var vf = "scale=\(w):\(h):force_original_aspect_ratio=decrease,pad=\(w):\(h):(ow-iw)/2:(oh-ih)/2:black,format=yuv420p"
        if let dt = buildDrawtextFilters(overlays: overlays, color: fontColor, fontSize: fontSize, glowEnabled: glowEnabled, glowColor: glowColor, glowIntensity: glowIntensity) {
            vf += "," + dt
        }
        log("Video filter string: \(vf)")
        let args: [String] = [
            path, "-y",
            "-loop", "1", "-i", image.path,
            "-t", durStr,
            "-r", fps,
            "-vf", vf,
            "-c:v", "libx264",
            "-pix_fmt", "yuv420p",
            "-profile:v", "high",
            "-level:v", "4.1",
            "-x264-params", "keyint=48:min-keyint=48:no-scenecut=1",
            "-an",
            "-f", "h264",
            out.path
        ]
        log("ffmpeg: \(args.joined(separator: " "))")
        try await run(args: args)
    }

    private func run(args: [String]) async throws {
        try await withCheckedThrowingContinuation { cont in
            let task = Process()
            task.environment = ProcEnv.augmented()
            task.launchPath = "/usr/bin/env"
            task.arguments = args
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = pipe
            if let killer = killer {
                DispatchQueue.main.async { [weak task] in
                    guard let task = task else { return }
                    killer.register(task)
                }
            }
            task.terminationHandler = { [weak killer, pipe, weak task] _ in
                if let killer = killer, let task = task {
                    DispatchQueue.main.async { [weak task] in
                        guard let task = task else { return }
                        killer.unregister(task)
                    }
                }
                let status = task?.terminationStatus ?? -1
                if status == 0 { 
                    cont.resume(returning: Void()) 
                } else {
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let s = String(data: data, encoding: .utf8) ?? ""
                    cont.resume(throwing: NSError(domain: "ffmpeg", code: Int(status), userInfo: [NSLocalizedDescriptionKey: s]))
                }
            }
            do { try task.run() } catch { cont.resume(throwing: error) }
        }
    }
}

struct VideoMaker {
    let ffmpeg: String
    let log: (String) -> Void
    weak var killer: ProcessKiller?

    func makeBlackVideo(
        duration: Double, fps: String, resolution: String,
        overlays: [Overlay], fontColor: String, fontSize: Int,
        glowEnabled: Bool, glowColor: String, glowIntensity: Int,
        outDir: URL
    ) async throws -> URL {
        let out = outDir.appendingPathComponent("black_\(Int(duration))s.h264")
        try await FFmpeg(path: ffmpeg, log: log, killer: killer).makeBlackH264(
            duration: duration, fps: fps, resolution: resolution,
            overlays: overlays, fontColor: fontColor, fontSize: fontSize,
            glowEnabled: glowEnabled, glowColor: glowColor, glowIntensity: glowIntensity,
            out: out
        )
        return out
    }

    func makeStillVideo(
        from image: URL, duration: Double, fps: String, resolution: String,
        overlays: [Overlay], fontColor: String, fontSize: Int,
        glowEnabled: Bool, glowColor: String, glowIntensity: Int,
        outDir: URL
    ) async throws -> URL {
        let out = outDir.appendingPathComponent("still_\(Int(duration))s.h264")
        try await FFmpeg(path: ffmpeg, log: log, killer: killer).makeStillH264(
            image: image, duration: duration, fps: fps, resolution: resolution,
            overlays: overlays, fontColor: fontColor, fontSize: fontSize,
            glowEnabled: glowEnabled, glowColor: glowColor, glowIntensity: glowIntensity,
            out: out
        )
        return out
    }
}

// MARK: - Chapters / Meta / tsMuxer

struct ChapterWriter {
    func writeChapters(durations: [Double], outDir: URL) throws -> URL {
        var lines: [String] = []
        var acc: Double = 0
        for (idx, d) in durations.enumerated() {
            let timestamp = Self.format(ts: acc)
            lines.append("\(timestamp) Chapter \(String(format: "%02d", idx+1))")
            acc += d
        }
        let url = outDir.appendingPathComponent("chapters.txt")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func format(ts: Double) -> String {
        let totalMs = Int(round(ts * 1000))
        let h = totalMs / 3600000
        let m = (totalMs % 3600000) / 60000
        let s = (totalMs % 60000) / 1000
        let ms = totalMs % 1000
        return String(format: "%02d:%02d:%02d.%03d", h, m, s, ms)
    }
}

struct TSMetaWriter {
    func writeMeta(videoPath: URL, audioPath: URL, audioType: TSMuxerAudioType, fps: String, chaptersPath: URL) throws -> URL {
        // Build custom chapters list → --custom-chapters=HH:MM:SS;... (rounded to nearest second)
        let raw = try String(contentsOf: chaptersPath, encoding: .utf8)
        let times: [String] = raw
            .split(separator: "\n")
            .compactMap { line -> String? in
                let token = line.split(separator: " ").first ?? Substring("")
                let tparts = token.split(separator: ":")
                guard tparts.count >= 3 else { return nil }
                let secParts = tparts[2].split(separator: ".")
                let h = Int(tparts[0]) ?? 0
                let m = Int(tparts[1]) ?? 0
                let s = Int(secParts.first ?? Substring("0")) ?? 0
                let ms = Int(secParts.count > 1 ? secParts[1] : "0") ?? 0
                var total = h * 3600 + m * 60 + s
                if ms >= 500 { total += 1 }
                let HH = String(format: "%02d", total / 3600)
                let MM = String(format: "%02d", (total % 3600) / 60)
                let SS = String(format: "%02d", total % 60)
                return "\(HH):\(MM):\(SS)"
            }
            .filter { !$0.isEmpty }
        let custom = times.joined(separator: ";")

        var meta = ""
        meta += "MUXOPT --blu-ray --vbr 20000 --auto-chapters=0"
        if !custom.isEmpty { meta += " --custom-chapters=\(custom)" }
        meta += "\n"
        // Video line
        meta += "V_MPEG4/ISO/AVC, \(videoPath.path)"
        let videoExt = videoPath.pathExtension.lowercased()
        if videoExt == "mp4" || videoExt == "mov" || videoExt == "mkv" || videoExt == "avi" {
            meta += ", track=1"
        }
        meta += ", fps=\(fps)"
        meta += ", level=4.1\n"
        // Audio line  
        meta += "\(audioType.metaToken), \(audioPath.path)"
        if audioType == .lpcm {
            meta += ", bitDepth=24"
        }
        // Add track parameter only for audio container formats that need it
        let audioExt = audioPath.pathExtension.lowercased()
        if audioExt == "mov" || audioExt == "mp4" || audioExt == "m4a" || audioExt == "mkv" || audioExt == "avi" {
            meta += ", track=1"
        }
        meta += ", lang=eng\n"
        let url = videoPath.deletingLastPathComponent().appendingPathComponent("author.meta")
        try meta.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

struct TSMuxer {
    let path: String
    let log: (String) -> Void
    weak var killer: ProcessKiller?

    func buildBluRay(metaPath: URL, outputDir: URL) async throws {
        let args = [path, metaPath.path, outputDir.path]
        log("tsMuxeR: \(args.joined(separator: " "))")
        try await run(args: args)
    }

    private func run(args: [String]) async throws {
        try await withCheckedThrowingContinuation { cont in
            let task = Process()
            task.environment = ProcEnv.augmented()
            task.launchPath = "/usr/bin/env"
            task.arguments = args
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = pipe
            if let killer = killer {
                DispatchQueue.main.async { [weak task] in
                    guard let task = task else { return }
                    killer.register(task)
                }
            }
            task.terminationHandler = { [weak killer, pipe, weak task] _ in
                if let killer = killer, let task = task {
                    DispatchQueue.main.async { [weak task] in
                        guard let task = task else { return }
                        killer.unregister(task)
                    }
                }
                let status = task?.terminationStatus ?? -1
                if status == 0 { 
                    cont.resume(returning: Void()) 
                } else {
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let s = String(data: data, encoding: .utf8) ?? ""
                    cont.resume(throwing: NSError(domain: "tsmuxer", code: Int(status), userInfo: [NSLocalizedDescriptionKey: s]))
                }
            }
            do { try task.run() } catch { cont.resume(throwing: error) }
        }
    }
}

// MARK: - Disc burning (via hdiutil + drutil)

final class DiscBurner {
    let log: (String) -> Void
    init(log: @escaping (String) -> Void) { self.log = log }

    func burnBDMV(from bdFolder: URL) throws {
        let fileMgr = FileManager.default
        let bdmv = bdFolder.appendingPathComponent("BDMV")
        guard fileMgr.fileExists(atPath: bdmv.path) else {
            throw NSError(domain: "burn", code: 1, userInfo: [NSLocalizedDescriptionKey: "Selected folder does not contain BDMV"])
        }

        let isoOut = bdFolder.deletingLastPathComponent().appendingPathComponent(bdFolder.lastPathComponent + ".iso")
        try makeUDFImage(from: bdFolder, to: isoOut)
        try drutilBurn(image: isoOut)
    }

    private func makeUDFImage(from folder: URL, to isoOut: URL) throws {
        let args = [
            "/usr/bin/hdiutil", "makehybrid",
            "-udf",
            "-udf-volume-name", "BDMV",
            "-o", isoOut.path,
            folder.path
        ]
        log("hdiutil: \(args.joined(separator: " "))")
        try runAndCheck(args: args)
        log("Created ISO: \(isoOut.path)")
    }

    private func drutilBurn(image: URL) throws {
        let args = ["/usr/sbin/drutil", "burn", image.path]
        log("drutil: \(args.joined(separator: " "))")
        try runAndCheck(args: args)
        log("Burn command sent to drive.")
    }

    private func runAndCheck(args: [String]) throws {
        let task = Process()
        task.environment = ProcEnv.augmented()
        task.launchPath = args.first
        task.arguments = Array(args.dropFirst())
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        try task.run()
        task.waitUntilExit()
        if task.terminationStatus != 0 {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let s = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "burn", code: Int(task.terminationStatus), userInfo: [NSLocalizedDescriptionKey: s])
        }
    }
}

// MARK: - Utilities

extension DateFormatter {
    static func compactTimestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f.string(from: Date())
    }
}

extension Int {
    func roundedInt() -> Int { return self }
}

extension Double {
    func roundedInt() -> Int { return Int((self).rounded()) }
}

// MARK: - Dependencies UI

struct DependenciesSheet: View {
    @ObservedObject var vm: AuthoringViewModel
    @State private var installingFFmpeg = false
    @State private var brewAvailable = false
    @State private var installingTS = false
    @State private var terminalKicked = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Dependencies").font(.title2).bold()
            Text("Install or point the app to external tools. Use Homebrew for ffmpeg/ffprobe. Download tsMuxeR from its releases and then point to it with Find…\nAutomatic install buttons below can fetch and place tools into Application Support so the app can use them without Homebrew.")

            GroupBox(label: Text("Paths")) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("ffprobe:").frame(width: 80, alignment: .trailing)
                        TextField("/opt/homebrew/bin/ffprobe", text: $vm.ffprobePath).textFieldStyle(RoundedBorderTextFieldStyle())
                        Button("Find…") { pickTool(title: "Choose ffprobe", binding: $vm.ffprobePath) }
                    }
                    HStack {
                        Text("ffmpeg:").frame(width: 80, alignment: .trailing)
                        TextField("/opt/homebrew/bin/ffmpeg", text: $vm.ffmpegPath).textFieldStyle(RoundedBorderTextFieldStyle())
                        Button("Find…") { pickTool(title: "Choose ffmpeg", binding: $vm.ffmpegPath) }
                    }
                    HStack {
                        Text("tsMuxer:").frame(width: 80, alignment: .trailing)
                        TextField("/usr/local/bin/tsmuxer", text: $vm.tsMuxerPath).textFieldStyle(RoundedBorderTextFieldStyle())
                        Button("Find…") { pickTool(title: "Choose tsMuxer", binding: $vm.tsMuxerPath) }
                    }
                }
                .padding(8)
            }

            GroupBox(label: Text("Installers")) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Button(installingFFmpeg ? "Installing ffmpeg…" : "Install ffmpeg via Homebrew") {
                            installingFFmpeg = true
                            vm.brewLog = ""
                            DispatchQueue.global(qos: .userInitiated).async {
                                Task {
                                    await runBrew("install ffmpeg")
                                }
                            }
                        }
                        .disabled(installingFFmpeg)

                        Button(installingTS ? "Installing tsMuxeR…" : "Install tsMuxeR automatically") {
                            installingTS = true
                            vm.brewLog += "\n[tsMuxeR] Resolving latest release…\n"
                            DispatchQueue.global(qos: .userInitiated).async {
                                Task {
                                    let (status, out) = await installTSMuxerAutomatically()
                                    DispatchQueue.main.async {
                                        vm.brewLog += out
                                        installingTS = false
                                        if status == 0 {
                                            let dest = appSupportBinURL().appendingPathComponent("tsmuxer").path
                                            vm.tsMuxerPath = dest
                                        }
                                    }
                                }
                            }
                        }
                        .disabled(installingTS)

                        Button(terminalKicked ? "Opened Terminal" : "Open Terminal & run setup") {
                            terminalKicked = true
                            openTerminalSetup()
                        }

                        Button("Open tsMuxeR Releases…") {
                            if let url = URL(string: "https://github.com/justdan96/tsMuxer/releases") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }

                    Text("Homebrew output:").font(.subheadline).padding(.top, 6)
                    ScrollView {
                        Text(vm.brewLog.isEmpty ? "(No output yet)" : vm.brewLog)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                    }
                    .frame(height: 160)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.3)))
                }
                .padding(8)
            }

            HStack {
                Spacer()
                Button("Close") { vm.showDepsSheet = false }
            }
        }
        .padding(16)
        .onAppear { checkBrew() }
    }

    private func pickTool(title: String, binding: Binding<String>) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedFileTypes = ["app", ""] // Allow both apps and executables
        panel.title = title
        if panel.runModal() == .OK, let url = panel.url {
            binding.wrappedValue = url.path
        }
    }

    private func checkBrew() {
        DispatchQueue.global(qos: .userInitiated).async {
            Task {
                let ok = await run("/bin/zsh", ["-lc", "command -v brew >/dev/null && echo ok || echo no"], capture: true).output.contains("ok")
                DispatchQueue.main.async {
                    brewAvailable = ok
                    if !ok { vm.brewLog = "Homebrew not found. Install from https://brew.sh (then reopen this sheet)." }
                }
            }
        }
    }

    private func runBrew(_ subcommand: String) async {
        if !brewAvailable {
            DispatchQueue.main.async {
                vm.brewLog += "Homebrew not detected.\n"
                installingFFmpeg = false
            }
            return
        }
        let result = await run("/bin/zsh", ["-lc", "brew \(subcommand)"], capture: true)
        DispatchQueue.main.async {
            vm.brewLog += result.output
            installingFFmpeg = false
        }
    }

    /// Attempts to download the latest macOS tsMuxeR and install to Application Support bin
    private func installTSMuxerAutomatically() async -> (Int32, String) {
        let dest = appSupportBinURL()
        try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let script = #"""
set -e
DEST="$HOME/Library/Application Support/BDAA-Authoring-Suite/bin"
mkdir -p "$DEST"
TMP=$(mktemp -d)
cd "$TMP"
URL=$(curl -s https://api.github.com/repos/justdan96/tsMuxer/releases/latest \
 | grep -i 'browser_download_url' \
 | grep -i -E 'mac|osx|darwin' \
 | grep -i -E 'zip|tar|dmg' \
 | head -n1 \
 | cut -d '"' -f4)
if [ -z "$URL" ]; then
  echo "Could not determine latest macOS tsMuxeR release URL from GitHub."
  exit 1
fi
echo "Downloading: $URL"
curl -L -o tsmuxer.dl "$URL"
FILETYPE=$(file -b tsmuxer.dl)
EXTRACTDIR=extract
mkdir -p "$EXTRACTDIR"
if echo "$FILETYPE" | grep -qi zip; then
  unzip -q tsmuxer.dl -d "$EXTRACTDIR"
elif echo "$FILETYPE" | grep -qi 'gzip\|bzip2\|tar'; then
  tar -xf tsmuxer.dl -C "$EXTRACTDIR"
else
  echo "Attempting to mount DMG…"
  MNT=$(hdiutil attach -nobrowse -quiet tsmuxer.dl | awk '/\/Volumes\//{print $3;exit}')
  if [ -n "$MNT" ]; then
    cp -R "$MNT"/* "$EXTRACTDIR"/
    hdiutil detach "$MNT" -quiet || true
  fi
fi
cd "$EXTRACTDIR"
CAND=$( (find . -type f -name tsmuxer -perm +111 2>/dev/null || find . -type f -name tsMuxeR -perm +111 2>/dev/null) | head -n1 )
if [ -z "$CAND" ]; then
  CAND=$( (find . -type f -name 'tsmuxer*' -perm +111 2>/dev/null) | head -n1 )
fi
if [ -z "$CAND" ]; then
  echo "Could not find tsmuxer binary in the downloaded archive."
  exit 2
fi
cp "$CAND" "$DEST/tsmuxer"
chmod +x "$DEST/tsmuxer"
echo "Installed tsMuxer to $DEST/tsmuxer"
"""#
        let cmd = ["-lc", script]
        return await run("/bin/zsh", cmd, capture: true)
    }

    /// Opens Terminal and runs a guided setup
    private func openTerminalSetup() {
        let script = #"""
set -e
/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal &>/dev/null &
/usr/bin/osascript <<'APPLESCRIPT'
 tell application "Terminal"
     activate
     do script "echo 'Installing ffmpeg via Homebrew…';\
which brew >/dev/null || echo 'Homebrew not found. Install from https://brew.sh';\
if which brew >/dev/null; then brew install ffmpeg; fi;\
\
DEST=\"$HOME/Library/Application Support/BDAA-Authoring-Suite/bin\";\
mkdir -p \"$DEST\";\
TMP=$(mktemp -d); cd \"$TMP\";\
URL=$(curl -s https://api.github.com/repos/justdan96/tsMuxer/releases/latest | grep -i browser_download_url | grep -i -E 'mac|osx|darwin' | grep -i -E 'zip|tar|dmg' | head -n1 | cut -d '\"' -f4);\
if [ -z \"$URL\" ]; then echo 'Could not resolve tsMuxer URL'; else echo Downloading: $URL; curl -L -o tsmuxer.dl \"$URL\"; FILETYPE=$(file -b tsmuxer.dl); mkdir -p extract; if echo \"$FILETYPE\" | grep -qi zip; then unzip -q tsmuxer.dl -d extract; elif echo \"$FILETYPE\" | grep -qi 'gzip\\|bzip2\\|tar'; then tar -xf tsmuxer.dl -C extract; else MNT=$(hdiutil attach -nobrowse -quiet tsmuxer.dl | awk '/\\/Volumes\\//{print $3;exit}'); if [ -n \"$MNT\" ]; then cp -R \"$MNT\"/* extract/; hdiutil detach \"$MNT\" -quiet || true; fi; fi; cd extract; CAND=$( (find . -type f -name tsmuxer -perm +111 2>/dev/null || find . -type f -name tsMuxeR -perm +111 2>/dev/null) | head -n1); if [ -n \"$CAND\" ]; then cp \"$CAND\" \"$DEST/tsmuxer\"; chmod +x \"$DEST/tsmuxer\"; echo Installed tsMuxer to $DEST/tsmuxer; else echo 'Could not find tsmuxer binary in archive'; fi; fi;\
\
echo 'All done. You can close this window.'"
 end tell
APPLESCRIPT
"""#
        DispatchQueue.global(qos: .background).async {
            Task {
                _ = await run("/bin/zsh", ["-lc", script], capture: false)
            }
        }
    }

    private func run(_ launchPath: String, _ args: [String], capture: Bool) async -> (status: Int32, output: String) {
        await withCheckedContinuation { cont in
            let task = Process()
            task.environment = ProcEnv.augmented()
            task.launchPath = launchPath
            task.arguments = args
            let pipe = Pipe()
            if capture { task.standardOutput = pipe; task.standardError = pipe }
            else { task.standardOutput = Pipe(); task.standardError = Pipe() }
            task.terminationHandler = { p in
                var s = ""
                if capture {
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    s = String(data: data, encoding: .utf8) ?? ""
                }
                cont.resume(returning: (p.terminationStatus, s))
            }
            do { try task.run() } catch { cont.resume(returning: (127, "Failed to run: \(error.localizedDescription)\n")) }
        }
    }
}

// MARK: - ScrollWheel (macOS)
struct ScrollWheel: NSViewRepresentable {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double = 1

    func makeNSView(context: Context) -> NSScrollWheelView {
        let v = NSScrollWheelView()
        v.value = value
        v.range = range
        v.step = step
        v.onChange = { newVal in
            DispatchQueue.main.async { self.value = newVal }
        }
        return v
    }
    func updateNSView(_ nsView: NSScrollWheelView, context: Context) {
        nsView.value = value
        nsView.range = range
        nsView.step = step
    }
}

final class NSScrollWheelView: NSView {
    var value: Double = 0
    var range: ClosedRange<Double> = 0...100
    var step: Double = 1
    var onChange: ((Double) -> Void)?

    private let label: NSTextField = {
        let l = NSTextField(labelWithString: "")
        l.font = .systemFont(ofSize: 12, weight: .semibold)
        l.alignment = .center
        l.textColor = NSColor.white
        return l
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(origin: .zero, size: NSSize(width: 72, height: 72)))
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.backgroundColor = NSColor(calibratedRed: 0.09, green: 0.14, blue: 0.23, alpha: 1).cgColor
        layer?.borderColor = NSColor(calibratedRed: 0.17, green: 0.23, blue: 0.35, alpha: 0.6).cgColor
        layer?.borderWidth = 1
        addSubview(label)
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }

    override func layout() {
        super.layout()
        label.frame = bounds.insetBy(dx: 6, dy: 6)
        label.stringValue = String(format: "%.0f", value)
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = Double(event.scrollingDeltaY)
        var newVal = value + (delta > 0 ? step : -step)
        newVal = min(max(newVal, range.lowerBound), range.upperBound)
        value = newVal
        label.stringValue = String(format: "%.0f", value)
        onChange?(value)
    }
}

// MARK: - View

struct ContentView: View {
    @StateObject private var vm = AuthoringViewModel()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            fileList
            Divider()
            controls
            Divider()
            if vm.showLog { logView }
        }
        .frame(minWidth: 980, minHeight: 700)
        .padding(8)
        .sheet(isPresented: $vm.showDepsSheet) { DependenciesSheet(vm: vm) }
        .preferredColorScheme(.dark)            // force dark regardless of system
        .background(Palette.bg)                 // app background
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image("Applogo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 200, height: 80)

            Spacer()
            Button("Add Files") { vm.addFiles() }
            Button("Remove") { vm.removeSelected() }
                .disabled(vm.selection.isEmpty)
            Button("Up") { vm.moveUp() }
                .disabled(vm.selection.isEmpty)
            Button("Down") { vm.moveDown() }
                .disabled(vm.selection.isEmpty)
            Button("Sort A–Z") { vm.sortAlphaNumericAscending() }
            Button("Dependencies / Install…") { vm.showDepsSheet = true }
        }
        .padding(12)
        .foregroundColor(Palette.text)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Palette.panel)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.border))
        )
        .padding(.bottom, 6)
    }

    private var fileList: some View {
        // Note: Table is iOS 16+/macOS 13+, using List for macOS 11.5 compatibility
        VStack(alignment: .leading) {
            HStack {
                Text("#").frame(width: 30)
                Text("File").frame(maxWidth: .infinity, alignment: .leading)
                Text("Codec").frame(width: 140)
                Text("SR").frame(width: 90)
                Text("Bit").frame(width: 70)
                Text("Ch").frame(width: 50)
                Text("Dur").frame(width: 100)
            }
            .font(.headline)
            .foregroundColor(Palette.text)
            .padding(.horizontal, 8)
            
            List(selection: $vm.selection) {
                ForEach(Array(vm.items.enumerated()), id: \.element.id) { index, item in
                    HStack {
                        Text("\(index + 1)").font(.system(.body, design: .monospaced)).frame(width: 30)
                        Text(item.url.deletingPathExtension().lastPathComponent)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(item.codecName ?? "?").frame(width: 140)
                        Text(item.sampleRate.map { "\($0)" } ?? "?").frame(width: 90)
                        Text(item.bitsPerSample.map { "\($0)" } ?? "?").frame(width: 70)
                        Text(item.channels.map { "\($0)" } ?? "?").frame(width: 50)
                        Text(formatDuration(item.duration)).frame(width: 100)
                    }
                    .tag(item.id)
                }
            }
        }
        .frame(maxHeight: 260)
        .foregroundColor(Palette.text)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Palette.panel)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.border))
        )
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            

            HStack {
                Picker("Output", selection: $vm.outputCodec) {
                    ForEach(OutputCodec.allCases) { oc in Text(oc.rawValue).tag(oc) }
                }.frame(width: 360)
                
                if vm.outputCodec == .lpcm {
                    Picker("Format", selection: $vm.lpcmFormat) {
                        ForEach(LPCMFormat.allCases) { format in Text(format.rawValue).tag(format) }
                    }.frame(width: 140)
                }
                
                Text("Video FPS:")
                TextField("23.976", text: $vm.videoFPS).frame(width: 80)
                Text("Resolution:")
                TextField("1920x1080", text: $vm.videoResolution).frame(width: 120)
                Picker("Disc", selection: $vm.targetDisc) {
                    ForEach(DiscCapacity.allCases) { d in Text(d.rawValue).tag(d) }
                }
                .frame(width: 220)
                Spacer()
                Text("Total:")
                Text(formatDuration(vm.totalDuration)).font(.system(.body, design: .monospaced))
            }
            

            

            

            
            // Video Mode Toggle
            HStack {
                Toggle("Custom Video", isOn: $vm.useCustomVideo)
                    .font(.headline)
                    .help("Enable to create custom video with cover art and track info. Disable for plain black screen.")
                Spacer()
            }
            
            // Video Options Section (only show when Custom Video is enabled)
            if vm.useCustomVideo {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Video Options").font(.headline)
                    
                    VStack(alignment: .leading, spacing: 12) {
                        // Cover Art Selection
                        HStack {
                            Text("Cover Art:")
                                .frame(width: 80, alignment: .leading)
                            TextField("No file selected", text: Binding(
                                get: { vm.coverArtPath?.path ?? "" },
                                set: { _ in }
                            ))
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .frame(width: 300)
                            .disabled(true)
                            Button("Choose…") {
                                vm.selectCoverArt()
                            }
                        }
                        
                        
                        // Artist/Album Override
                        HStack {
                            VStack(alignment: .leading) {
                                Toggle("Show Artist", isOn: $vm.showArtist)
                                if vm.showArtist {
                                    TextField("Custom Artist", text: $vm.customArtist)
                                        .textFieldStyle(RoundedBorderTextFieldStyle())
                                        .frame(width: 200)
                                }
                            }
                            
                            Spacer().frame(width: 20)
                            
                            VStack(alignment: .leading) {
                                Toggle("Show Album", isOn: $vm.showAlbum)
                                if vm.showAlbum {
                                    TextField("Custom Album", text: $vm.customAlbum)
                                        .textFieldStyle(RoundedBorderTextFieldStyle())
                                        .frame(width: 200)
                                }
                            }
                        }
                        
                        // Background Options
                        HStack {
                            Text("Background:")
                                .frame(width: 80, alignment: .leading)
                            Picker("", selection: $vm.backgroundType) {
                                ForEach(BackgroundType.allCases) { bg in
                                    Text(bg.rawValue).tag(bg)
                                }
                            }
                            .frame(width: 140)
                            
                            switch vm.backgroundType {
                            case .solid:
                                ColorPicker("Color", selection: Binding(
                                    get: { Color(vm.solidColor) },
                                    set: { vm.solidColor = NSColor($0) }
                                ))
                                .frame(width: 100)
                            case .gradient:
                                ColorPicker("Start", selection: Binding(
                                    get: { Color(vm.gradientStartColor) },
                                    set: { vm.gradientStartColor = NSColor($0) }
                                ))
                                .frame(width: 80)
                                ColorPicker("End", selection: Binding(
                                    get: { Color(vm.gradientEndColor) },
                                    set: { vm.gradientEndColor = NSColor($0) }
                                ))
                                .frame(width: 80)
                            case .image:
                                TextField("No image selected", text: Binding(
                                    get: { vm.backgroundImagePath?.path ?? "" },
                                    set: { _ in }
                                ))
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .frame(width: 200)
                                .disabled(true)
                                Button("Choose…") {
                                    vm.selectBackgroundImage()
                                }
                            }
                        }
                        
                        // Border and Text Options
                        HStack {
                            Toggle("Show Border", isOn: $vm.showBorder)
                            if vm.showBorder {
                                Picker("Border Color", selection: $vm.borderColor) {
                                    ForEach(BorderColor.allCases) { color in
                                        Text(color.rawValue).tag(color)
                                    }
                                }
                                .frame(width: 120)
                            }
                            
                            Spacer().frame(width: 20)
                            
                            ColorPicker("Title Color", selection: Binding(
                                get: { Color(vm.trackTitleColor) },
                                set: { vm.trackTitleColor = NSColor($0) }
                            ))
                            .frame(width: 120)
                        }
                        
                        // Text Glow Options
                        HStack {
                            Toggle("Text Glow", isOn: $vm.enableTextGlow)
                            if vm.enableTextGlow {
                                Picker("Glow Color", selection: $vm.textGlowColor) {
                                    ForEach(TextGlowColor.allCases) { color in
                                        Text(color.rawValue).tag(color)
                                    }
                                }
                                .frame(width: 120)
                                
                                Text("Intensity:")
                                Slider(value: $vm.textGlowIntensity, in: 1...10, step: 0.5)
                                    .frame(width: 100)
                                Text(String(format: "%.1f", vm.textGlowIntensity))
                                    .frame(width: 30)
                            }
                        }
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Palette.bg)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.border, lineWidth: 1))
                    )
                }
            }

            HStack {
                LabeledTextField(label: "ffprobe", text: $vm.ffprobePath)
                LabeledTextField(label: "ffmpeg", text: $vm.ffmpegPath)
                LabeledTextField(label: "tsMuxeR", text: $vm.tsMuxerPath)
                Spacer()
                Button("Choose Output Folder…") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    panel.canCreateDirectories = true
                    if panel.runModal() == .OK { vm.outputDirectory = panel.urls.first }
                }
            }

            HStack(spacing: 12) {
                ProgressView(value: vm.progress) {
                    Text(vm.statusText.isEmpty ? (vm.isWorking ? "Working…" : "Idle") : vm.statusText)
                }
                .frame(maxWidth: 380)
                .padding(.trailing, 8)
                Text(String(format: "%.0f%%", vm.progress * 100)).font(.system(.body, design: .monospaced)).frame(width: 44, alignment: .trailing)
                Text("Estimated: \(formatBytes(vm.estimatedSizeBytes)) / \(formatBytes(vm.targetDisc.bytes))")
                    .foregroundColor(vm.estimatedSizeBytes > vm.targetDisc.bytes ? .red : Palette.subtext)
                    .font(.system(.body, design: .monospaced))
                Spacer()
            }

            HStack {
                Button(vm.isWorking ? "Working…" : "Build Blu-ray Folder") { vm.buildBluRayFolder() }
                    .disabled(vm.isWorking || vm.items.isEmpty)
                Button("Cancel") { vm.cancelBuild() }
                    .disabled(!vm.isWorking)
                Button("Burn Blu-ray…") { vm.burnBluRay() }
                Spacer()
                Toggle(vm.showLog ? "Hide Log" : "Show Log", isOn: $vm.showLog)
                    .frame(width: 140)
            }
        }
        .foregroundColor(Palette.text)
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Palette.panel)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.border))
        )
    }

    private var logView: some View {
        VStack(alignment: .leading) {
            Text("Log").font(.headline)
            TextEditor(text: .constant(vm.logText))
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(Palette.text)
            .frame(minHeight: 220)
            .background(Palette.panel)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.border))
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Palette.panel)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.border))
        )
    }

    private func formatBytes(_ n: UInt64) -> String {
        let dbl = Double(n)
        if dbl >= 1_000_000_000 { return String(format: "%.2f GB", dbl/1_000_000_000) }
        if dbl >= 1_000_000 { return String(format: "%.1f MB", dbl/1_000_000) }
        if dbl >= 1_000 { return String(format: "%.0f KB", dbl/1_000) }
        return "\(n) B"
    }

    private func formatDuration(_ d: Double?) -> String {
        guard let d = d else { return "?" }
        let s = Int(d.rounded())
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%02d:%02d", m, sec)
    }
}

struct LabeledTextField: View {
    let label: String
    @Binding var text: String
    var body: some View {
        HStack {
            Text(label + ":").frame(width: 70, alignment: .trailing).foregroundColor(Palette.subtext)
            TextField(label, text: $text)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .frame(width: 220)
        }
    }
}

// MARK: - Preview

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .frame(width: 1000, height: 720)
    }
}
