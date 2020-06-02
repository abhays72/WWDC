//
//  ClipRenderer.swift
//  WWDC
//
//  Created by Guilherme Rambo on 02/06/20.
//  Copyright © 2020 Guilherme Rambo. All rights reserved.
//

import Cocoa
import AVFoundation
import os.log

final class ClipRenderer: NSObject {

    private let log = OSLog(subsystem: "WWDC", category: String(describing: ClipRenderer.self))

    let playerItem: AVPlayerItem
    let fileNameHint: String?

    init(playerItem: AVPlayerItem, fileNameHint: String?) {
        self.playerItem = playerItem
        self.fileNameHint = fileNameHint

        super.init()
    }

    private func generateOutputURL() -> URL {
        let basename = fileNameHint ?? UUID().uuidString
        let filename = basename + "-" + String(Int(Date().timeIntervalSinceReferenceDate))

        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(filename)
            .appendingPathExtension("mp4")
    }

    private(set) lazy var outputURL: URL = {
        generateOutputURL()
    }()

    private func error(with message: String) -> Error {
        NSError(domain: "io.wwdc.ClipRenderer", code: 0, userInfo: [NSLocalizedRecoverySuggestionErrorKey: message])
    }

    typealias RenderProgressBlock = (Float) -> Void
    typealias RenderCompletionBlock = (Result<URL, Error>) -> Void

    private var progressHandler: RenderProgressBlock?
    private var completionHandler: RenderCompletionBlock?

    private var currentSession: AVAssetExportSession?

    func renderClip(progress: @escaping RenderProgressBlock, completion: @escaping RenderCompletionBlock) {
        os_log("%{public}@", log: log, type: .debug, #function)

        progressHandler = progress
        completionHandler = completion

        let preset = AVAssetExportPreset1280x720

        guard let session = AVAssetExportSession(asset: playerItem.asset, presetName: preset) else {
            completion(.failure(error(with: "The export session couldn't be initialized.")))
            return
        }

        currentSession = session

        startExport(with: session)

        startProgressReporting()
    }

    private func startExport(with session: AVAssetExportSession) {
        session.outputFileType = .mp4
        session.outputURL = outputURL

        os_log("Will output to %@", log: self.log, type: .debug, outputURL.path)

        let startTime = playerItem.reversePlaybackEndTime
        let endTime = playerItem.forwardPlaybackEndTime
        let timeRange = CMTimeRangeFromTimeToTime(start: startTime, end: endTime)
        session.timeRange = timeRange

        session.exportAsynchronously { [weak session, weak self] in
            guard let self = self else { return }
            guard let session = session else { return }

            switch session.status {
            case .unknown:
                os_log("Export session received unknown status")
            case .waiting:
                os_log("Export session waiting")
            case .exporting:
                os_log("Export session started")
            case .completed:
                os_log("Export session finished")

                self.reportCompletion(with: .success(self.outputURL))
            case .failed:
                if let error = session.error {
                    os_log("Export session failed with error: %{public}@", log: self.log, type: .error, String(describing: error))
                } else {
                    os_log("Export session failed with an unknown error", log: self.log, type: .error)
                }

                self.reportCompletion(with: .failure(self.error(with: "The export failed.")))
            case .cancelled:
                self.reportCompletion(with: .failure(self.error(with: "The export was cancelled.")))
            @unknown default:
                fatalError("Unknown case")
            }
        }
    }

    private var progressUpdateTimer: Timer?

    private var currentProgress: Float = 0 {
        didSet {
            guard currentProgress != oldValue else { return }

            reportProgress(currentProgress)
        }
    }

    private func startProgressReporting() {
        let progressCheckInterval: TimeInterval = 0.1

        progressUpdateTimer = Timer.scheduledTimer(withTimeInterval: progressCheckInterval, repeats: true, block: { [weak self] timer in
            guard let self = self else { return }

            guard self.currentSession?.status == .exporting else {
                timer.invalidate()
                self.progressUpdateTimer = nil
                return
            }

            self.currentProgress = self.currentSession?.progress ?? 0
        })
    }

    func cancel() {
        currentSession?.cancelExport()
        currentSession = nil
    }

    private func reportProgress(_ value: Float) {
        DispatchQueue.main.async {
            self.progressHandler?(value)
        }
    }

    private func reportCompletion(with result: Result<URL, Error>) {
        DispatchQueue.main.async {
            self.completionHandler?(result)
        }
    }

}
