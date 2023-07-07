//
//  AespaPhotoContext.swift
//  
//
//  Created by 이영빈 on 2023/06/22.
//

import Combine
import Foundation
import AVFoundation

/// `AespaPhotoContext` is an open class that provides a context for photo capturing operations.
/// It has methods and properties to handle the photo capturing and settings.
open class AespaPhotoContext {
    private let coreSession: AespaCoreSession
    private let albumManager: AespaCoreAlbumManager
    private let option: AespaOption
    
    private let camera: AespaCoreCamera
    
    private var photoSetting: AVCapturePhotoSettings
    private let photoFileBufferSubject: CurrentValueSubject<Result<PhotoFile, Error>?, Never>
    
    init(
        coreSession: AespaCoreSession,
        camera: AespaCoreCamera,
        albumManager: AespaCoreAlbumManager,
        option: AespaOption
    ) {
        self.coreSession = coreSession
        self.camera = camera
        self.albumManager = albumManager
        self.option = option
        
        self.photoSetting = AVCapturePhotoSettings()
        self.photoFileBufferSubject = .init(nil)
        
        // Add first video file to buffer if it exists
        Task(priority: .utility) {
            guard let firstPhotoAsset = await albumManager.fetchPhotoFile(limit: 1).first else {
                return
            }
            
            photoFileBufferSubject.send(.success(firstPhotoAsset.toPhotoFile))
        }
    }
}

extension AespaPhotoContext: PhotoContext {
    public var underlyingPhotoContext: AespaPhotoContext {
        self
    }
    
    public var photoFilePublisher: AnyPublisher<Result<PhotoFile, Error>, Never> {
        photoFileBufferSubject.handleEvents(receiveOutput: { status in
            if case .failure(let error) = status {
                Logger.log(error: error)
            }
        })
        .compactMap({ $0 })
        .eraseToAnyPublisher()
    }
    
    public var currentSetting: AVCapturePhotoSettings {
        photoSetting
    }
    
    public func capturePhoto(
        _ completionHandler: @escaping (Result<PhotoFile, Error>) -> Void
    ) {
        Task(priority: .utility) {
            do {
                let photoFile = try await self.capturePhotoWithError()
                completionHandler(.success(photoFile))
            } catch let error {
                Logger.log(error: error)
                completionHandler(.failure(error))
            }
        }
    }
    
    @discardableResult
    public func flashMode(to mode: AVCaptureDevice.FlashMode) -> AespaPhotoContext {
        photoSetting.flashMode = mode
        return self
    }
    
    @discardableResult
    public func redEyeReduction(enabled: Bool) -> AespaPhotoContext {
        photoSetting.isAutoRedEyeReductionEnabled = enabled
        return self
    }
    
    public func custom(_ setting: AVCapturePhotoSettings) -> AespaPhotoContext {
        photoSetting = setting
        return self
    }
    
    public func fetchPhotoFiles(limit: Int) async -> [PhotoAsset] {
        return await albumManager.fetchPhotoFile(limit: limit)
    }
}

private extension AespaPhotoContext {
    func capturePhotoWithError() async throws -> PhotoFile {
        let setting = AVCapturePhotoSettings(from: photoSetting)
        let capturePhoto = try await camera.capture(setting: setting)
        
        guard let rawPhotoData = capturePhoto.fileDataRepresentation() else {
            throw AespaError.file(reason: .unableToFlatten)
        }
        
        if option.asset.synchronizeWithLocalAlbum {
            // Register to album
            try await albumManager.addToAlbum(imageData: rawPhotoData)
        }
        
        let photoFile = PhotoFileGenerator.generate(
            data: rawPhotoData,
            date: Date())
        
        photoFileBufferSubject.send(.success(photoFile))
        return photoFile
    }
}
