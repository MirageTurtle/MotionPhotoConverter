import Foundation
import Photos
import LivePhoto

// MARK: - CLI Arguments

struct Arguments {
    let inputDir: String
    let outputDir: String? // nil = save to Photos library

    static func parse() -> Arguments? {
        let args = CommandLine.arguments
        var inputDir: String?
        var outputDir: String?
        var i = 1
        while i < args.count {
            switch args[i] {
            case "--input", "-i":
                i += 1
                guard i < args.count else { return nil }
                inputDir = args[i]
            case "--output", "-o":
                i += 1
                guard i < args.count else { return nil }
                outputDir = args[i]
            default:
                break
            }
            i += 1
        }
        guard let inputDir = inputDir else {
            print("Usage: MotionPhotoConverter --input <directory> [--output <directory>]")
            return nil
        }
        return Arguments(inputDir: inputDir, outputDir: outputDir)
    }
}

// MARK: - Async wrappers

func generateLivePhoto(mp4URL: URL, imageURL: URL?, creationDate: Date?) async throws -> LivePhoto.LivePhotoResources {
    try await withCheckedThrowingContinuation { continuation in
        LivePhoto.generate(
            from: imageURL,
            videoURL: mp4URL,
            creationDate: creationDate,
            progress: { _ in },
            completion: { livePhoto, resources in
                if let resources = resources {
                    continuation.resume(returning: resources)
                } else {
                    continuation.resume(throwing: AppError.livePhotoGenerationFailed)
                }
            }
        )
    }
}

func saveToLibrary(_ resources: LivePhoto.LivePhotoResources, creationDate: Date?) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        LivePhoto.saveToLibrary(resources, creationDate: creationDate) { success in
            if success {
                continuation.resume()
            } else {
                continuation.resume(throwing: AppError.saveToLibraryFailed)
            }
        }
    }
}

func requestPhotoLibraryAccess() async -> Bool {
    let status = PHPhotoLibrary.authorizationStatus()
    switch status {
    case .authorized, .limited:
        return true
    case .notDetermined:
        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization { newStatus in
                continuation.resume(returning: newStatus == .authorized || newStatus == .limited)
            }
        }
    default:
        return false
    }
}

// MARK: - App Logic

enum AppError: LocalizedError {
    case livePhotoGenerationFailed
    case saveToLibraryFailed

    var errorDescription: String? {
        switch self {
        case .livePhotoGenerationFailed: return "Live Photo generation failed"
        case .saveToLibraryFailed: return "Save to Photos library failed"
        }
    }
}

func processBatch(inputDir: String, outputDir: String?) async {
    let fm = FileManager.default
    guard let files = try? fm.contentsOfDirectory(atPath: inputDir) else {
        print("ERROR: Cannot read input directory: \(inputDir)")
        return
    }

    let inputExtensions = Set(["jpg", "jpeg", "heic"])
    let inputFiles = files.filter { inputExtensions.contains(($0 as NSString).pathExtension.lowercased()) }

    guard !inputFiles.isEmpty else {
        print("No supported files (jpg/jpeg/heic) found in \(inputDir)")
        return
    }

    // Ensure output directory exists
    if let outputDir = outputDir {
        try? fm.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
    } else {
        let authorized = await requestPhotoLibraryAccess()
        guard authorized else {
            print("ERROR: Photo Library access is required to save Live Photos.")
            print("Grant access in System Settings > Privacy & Security > Photos.")
            return
        }
    }

    print("Processing \(inputFiles.count) files...")
    var successCount = 0
    var skipCount = 0
    var failCount = 0

    for (index, filename) in inputFiles.enumerated() {
        let filePath = (inputDir as NSString).appendingPathComponent(filename)
        let fileURL = URL(fileURLWithPath: filePath)
        print("[\(index + 1)/\(inputFiles.count)] \(filename) ... ", terminator: "")

        do {
            // Step 1: Extract MP4 + EXIF date
            let extraction = try MotionPhotoExtractor.extractMP4(from: fileURL)

            // Step 2: Generate Live Photo (library automatically converts to MOV internally)
            let resources = try await generateLivePhoto(
                mp4URL: extraction.mp4URL,
                imageURL: fileURL,
                creationDate: extraction.exifDate
            )

            // Step 3: Save
            if let outputDir = outputDir {
                // Save paired resources to output directory
                let baseName = (filename as NSString).deletingPathExtension
                let destImage = URL(fileURLWithPath: outputDir).appendingPathComponent("\(baseName).jpg")
                let destVideo = URL(fileURLWithPath: outputDir).appendingPathComponent("\(baseName).mov")
                try? fm.removeItem(at: destImage)
                try? fm.removeItem(at: destVideo)
                try fm.copyItem(at: resources.pairedImage, to: destImage)
                try fm.copyItem(at: resources.pairedVideo, to: destVideo)
                print("saved to \(outputDir)")
            } else {
                try await saveToLibrary(resources, creationDate: extraction.exifDate)
                print("saved to Photos")
            }

            successCount += 1

            // Clean up temp MP4
            try? fm.removeItem(at: extraction.mp4URL)

        } catch MotionPhotoExtractor.ExtractionError.noEmbeddedVideo {
            print("SKIP (no embedded video)")
            skipCount += 1
        } catch {
            print("FAIL (\(error.localizedDescription))")
            failCount += 1
        }
    }

    print("\nDone. \(successCount) succeeded, \(skipCount) skipped, \(failCount) failed.")
}

// MARK: - Entry Point

guard let args = Arguments.parse() else {
    exit(1)
}

let semaphore = DispatchSemaphore(value: 0)
Task {
    await processBatch(inputDir: args.inputDir, outputDir: args.outputDir)
    semaphore.signal()
}
DispatchQueue.global().async {
    semaphore.wait()
    exit(0)
}
dispatchMain()
