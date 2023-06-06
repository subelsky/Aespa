//
//  AespaSession.swift
//  
//
//  Created by Young Bin on 2023/06/03.
//

import UIKit
import Combine
import Foundation
import AVFoundation

open class AespaSession {
    private let option: AespaOption
    private let session: AespaCoreSession
    private let recorder: AespaCoreRecorder
    private let fileManager: FileManager
    private let albumManager: AespaCoreAlbumManager
    
    private var currentRecordingURL: URL?
    private let videoFileBufferSubject: CurrentValueSubject<Result<VideoFile, Error>?, Never>
    private let previewLayerSubject: CurrentValueSubject<AVCaptureVideoPreviewLayer?, Never>
    
    convenience init(option: AespaOption) {
        let session = AespaCoreSession(option: option)
        Logger.enableLogging = option.log.enableLogging
        
        self.init(
            option: option,
            session: session,
            recorder: .init(core: session),
            fileManager: .default,
            albumManager: .init(albumName: option.asset.albumName)
        )
    }
    
    init(
        option: AespaOption,
        session: AespaCoreSession,
        recorder: AespaCoreRecorder,
        fileManager: FileManager,
        albumManager: AespaCoreAlbumManager
    ) {
        self.option = option
        self.session = session
        self.recorder = recorder
        self.fileManager = fileManager
        self.albumManager = albumManager
        
        self.videoFileBufferSubject = .init(nil)
        self.previewLayerSubject = .init(nil)
        
        // Add first file to buffer if it exists
        if let firstVideoFile = fetch(count: 1).first {
            self.videoFileBufferSubject.send(.success(firstVideoFile))
        }
    }
    
    // MARK: vars
    public var previewLayer: AVCaptureVideoPreviewLayer {
        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.connection?.videoOrientation = .portrait
        
        return previewLayer
    }
    
    public var maxZoomFactor: CGFloat? {
        guard let videoDeviceInput = session.videoDevice else { return nil }
        return videoDeviceInput.device.activeFormat.videoMaxZoomFactor
    }
    
    public var currentZoomFactor: CGFloat? {
        guard let videoDeviceInput = session.videoDevice else { return nil }
        return videoDeviceInput.device.videoZoomFactor
    }
    
    public var videoFilePublisher: AnyPublisher<Result<VideoFile, Error>, Never> {
        recorder.fileIOResultPublihser.map { status in
            switch status {
            case .success(let url):
                return .success(VideoFileGenerator.generate(with: url))
            case .failure(let error):
                Logger.log(error: error)
                return .failure(error)
            }
        }
        .merge(with: videoFileBufferSubject.eraseToAnyPublisher())
        .compactMap { $0 }
        .eraseToAnyPublisher()
    }
    
    public var previewLayerPublisher: AnyPublisher<AVCaptureVideoPreviewLayer, Never> {
        previewLayerSubject.handleEvents(receiveOutput: { _ in
            Logger.log(message: "Preview layer is updated")
        })
        .compactMap { $0 }
        .eraseToAnyPublisher()
    }
    
    // MARK: - Methods
    public func startRecording() throws {
        let fileName = option.asset.fileNameHandler()
        let filePath = try VideoFilePathProvider.requestFilePath(
            from: fileManager,
            directoryName: option.asset.albumName,
            fileName: fileName)
        
        if option.session.autoVideoOrientation {
            setOrientation(to: UIDevice.current.orientation.toVideoOrientation)
        }
        
        try recorder.startRecording(in: filePath)
        
        currentRecordingURL = filePath
    }
    
    public func stopRecording() throws {
        try recorder.stopRecording()
        
        if let currentRecordingURL {
            Task(priority: .utility) { try await albumManager.addToAlbum(filePath: currentRecordingURL) }
        }
    }
    
    // MARK: Chaining
    @discardableResult
    public func mute() throws -> Self {
        let tuner = AudioTuner(isMuted: true)
        try session.run(tuner)
        return self
    }

    @discardableResult
    public func unmute() throws -> Self {
        let tuner = AudioTuner(isMuted: false)
        try session.run(tuner)
        return self
    }

    @discardableResult
    public func setQuality(to preset: AVCaptureSession.Preset) throws -> Self {
        let tuner = QualityTuner(videoQuality: preset)
        try session.run(tuner)
        return self
    }

    @discardableResult
    public func setPosition(to position: AVCaptureDevice.Position) throws -> Self {
        let tuner = CameraPositionTuner(position: position)
        try session.run(tuner)
        return self
    }
    
    // MARK: No throws
    @discardableResult
    public func setOrientation(to orientation: AVCaptureVideoOrientation) -> Self {
        let tuner = VideoOrientationTuner(orientation: orientation)
        try? session.run(tuner)
        return self
    }

    @discardableResult
    public func setStabilization(mode: AVCaptureVideoStabilizationMode) -> Self {
        let tuner = VideoStabilizationTuner(stabilzationMode: mode)
        try? session.run(tuner)
        return self
    }

    @discardableResult
    public func zoom(factor: CGFloat) -> Self {
        let tuner = ZoomTuner(zoomFactor: factor)
        try? session.run(tuner)
        return self
    }
    
    // MARK: customizable
    public func custom(_ tuner: some AespaSessionTuning) throws {
        try session.run(tuner)
    }
    
    // MARK: Util
    public func fetchVideoFiles(limit: Int = 0) -> [VideoFile] {
        return fetch(count: limit)
    }
    
    /// Check if essential(and minimum) condition for starting recording is satisfied
    public func doctor() async throws {
        // Check authorization status
        guard
            case .permitted = await AuthorizationChecker.checkCaptureAuthorizationStatus()
        else {
            throw AespaError.permission(reason: .denied)
        }
        
        guard session.isRunning else {
            throw AespaError.session(reason: .notRunning)
        }
        
        // Check if connection exists
        guard session.movieOutput != nil else {
            throw AespaError.session(reason: .cannotFindConnection)
        }
        
        // Check if device is attached
        guard session.videoDevice != nil else {
            throw AespaError.session(reason: .cannotFindDevice)
        }
    }
    
    // MARK: Internal
    func startSession() throws {
        let tuner = SessionLaunchTuner()
        try session.run(tuner)
        
        previewLayerSubject.send(previewLayer)
    }
}

private extension AespaSession {
    /// If `count` is `0`, return all files
    func fetch(count: Int) -> [VideoFile] {
        guard count >= 0 else { return [] }
        
        do {
            let directoryPath = try VideoFilePathProvider.requestDirectoryPath(from: fileManager,
                                                                               name: option.asset.albumName)
            
            let filePaths = try fileManager.contentsOfDirectory(atPath: directoryPath.path)
            let filePathPrefix = count == 0 ? filePaths : Array(filePaths.prefix(count))
            
            return filePathPrefix
                .map { name -> URL in
                    return directoryPath.appendingPathComponent(name)
                }
                .map { filePath -> VideoFile in
                    return VideoFileGenerator.generate(with: filePath)
                }
        } catch let error {
            Logger.log(error: error)
            return []
        }
    }
}