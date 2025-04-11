import Foundation
import PhotosUI
import Photos // Added import for photo library permissions
import CoreLocation // Added import for handling GPS coordinates

/// An implementation of [image_picker](https://pub.dev/packages/image_picker) for macOS using [PHPicker](https://developer.apple.com/documentation/photokit/phpickerviewcontroller).
///
/// The package [image_picker_macos](https://pub.dev/packages/image_picker_macos) depends on [file_selector_macos](https://pub.dev/packages/file_selector_macos)
/// for picking images, videos, and media. It has limited support for resizing and compression and uses the system file picker, this implementation is used by the Dart plugin
/// to use [PHPickerViewController](https://developer.apple.com/documentation/photokit/phpickerviewcontroller) which is supported on macOS 13.0+
/// otherwise fallback to file selector if unsupported or the user prefers the file selector implementation.
class ImagePickerImpl: NSObject, ImagePickerApi {
    private let view: NSView?
    
    init(view: NSView?) {
        self.view = view
    }
    
    /// Returns `true` if the current macOS version supports this feature.
    ///
    /// `PHPicker` is supported on macOS 13.0+.
    /// For more information, see [PHPickerViewController](https://developer.apple.com/documentation/photokit/phpickerviewcontroller).
    func supportsPHPicker() -> Bool {
        guard #available(macOS 13.0, *) else {
            return false
        }
        return true
    }
    
    private var pickImagesDelegate: PickImagesDelegate?
    private var pickVideosDelegate: PickVideosDelegate?
    private var pickMediaDelegate: PickMediaDelegate?
    
    /// Requests photo library permissions if not already granted.
    ///
    /// - Parameter completion: A closure that is called with a boolean indicating whether access is granted.
    private func requestPhotoLibraryPermission(completion: @escaping (Bool) -> Void) {
        let status = PHPhotoLibrary.authorizationStatus()
        switch status {
        case .authorized, .limited:
            completion(true)
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization { newStatus in
                DispatchQueue.main.async {
                    completion(newStatus == .authorized || newStatus == .limited)
                }
            }
        default:
            completion(false)
        }
    }
    
    func pickImages(
        options: ImageSelectionOptions, generalOptions: GeneralOptions,
        completion: @escaping (Result<any ImagePickerResult, any Error>) -> Void
    ) {
        requestPhotoLibraryPermission { granted in
            guard granted else {
                completion(.success(ImagePickerErrorResult(error: .phpickerUnsupported)))
                return
            }
            guard #available(macOS 13.0, *) else {
                completion(.success(ImagePickerErrorResult(error: .phpickerUnsupported)))
                return
            }
            
            var config = PHPickerConfiguration(photoLibrary: PHPhotoLibrary.shared())
            config.selectionLimit = Int(generalOptions.limit)
            config.filter = .images
            config.preferredAssetRepresentationMode = .current
            
            let picker = PHPickerViewController(configuration: config)
            
            self.pickImagesDelegate = PickImagesDelegate(
                completion: completion,
                options: options
            )
            picker.delegate = self.pickImagesDelegate
            
            self.showPHPicker(
                picker,
                noActiveWindow: {
                    completion(.success(ImagePickerErrorResult(error: .windowNotFound)))
                })
        }
    }
    
    func pickVideos(
        generalOptions: GeneralOptions,
        completion: @escaping (Result<any ImagePickerResult, any Error>) -> Void
    ) {
        requestPhotoLibraryPermission { granted in
            guard granted else {
                completion(.success(ImagePickerErrorResult(error: .phpickerUnsupported)))
                return
            }
            guard #available(macOS 13.0, *) else {
                completion(.success(ImagePickerErrorResult(error: .phpickerUnsupported)))
                return
            }
            
            if generalOptions.limit != nil && generalOptions.limit != 1 {
                completion(.success(ImagePickerErrorResult(error: .multiVideoSelectionUnsupported)))
                return
            }
            
            var config = PHPickerConfiguration()
            config.selectionLimit = 1
            config.filter = .videos
            
            let picker = PHPickerViewController(configuration: config)
            self.pickVideosDelegate = PickVideosDelegate(completion: completion)
            picker.delegate = self.pickVideosDelegate
            
            self.showPHPicker(
                picker,
                noActiveWindow: {
                    completion(.success(ImagePickerErrorResult(error: .windowNotFound)))
                })
        }
    }
    
    func pickMedia(
        options: MediaSelectionOptions, generalOptions: GeneralOptions,
        completion: @escaping (Result<any ImagePickerResult, any Error>) -> Void
    ) {
        requestPhotoLibraryPermission { granted in
            guard granted else {
                completion(.success(ImagePickerErrorResult(error: .phpickerUnsupported)))
                return
            }
            guard #available(macOS 13.0, *) else {
                completion(.success(ImagePickerErrorResult(error: .phpickerUnsupported)))
                return
            }
            
            var config = PHPickerConfiguration()
            config.selectionLimit = Int(generalOptions.limit)
            config.filter = PHPickerFilter.any(of: [.images, .videos])
            
            let picker = PHPickerViewController(configuration: config)
            self.pickMediaDelegate = PickMediaDelegate(completion: completion, options: options)
            picker.delegate = self.pickMediaDelegate
            
            self.showPHPicker(
                picker,
                noActiveWindow: {
                    completion(.success(ImagePickerErrorResult(error: .windowNotFound)))
                })
        }
    }
    
    @available(macOS 13, *)
    private func showPHPicker(_ picker: PHPickerViewController, noActiveWindow: @escaping () -> Void)
    {
        guard let window = view?.window else {
            noActiveWindow()
            return
        }
        
        // A similar initial sheet size to PhotosPicker in a macOS SwiftUI app.
        picker.view.frame = NSRect(x: 0, y: 0, width: 780, height: 615)
        
        window.contentViewController?.presentAsSheet(picker)
        
        // A similar minimum sheet size to PhotosPicker in a macOS SwiftUI app.
        picker.view.window?.contentMinSize = NSSize(width: 320, height: 200)
    }
    
    func openPhotosApp() -> Bool {
        guard let url = URL(string: "photos://") else {
            return false
        }
        
        let workspace = NSWorkspace.shared
        let canOpen = workspace.urlForApplication(toOpen: url) != nil
        
        guard canOpen else {
            return false
        }
        
        workspace.open(url)
        
        return true
    }
}

class PickImagesDelegate: PHPickerViewControllerDelegate {
    private let completion: ((Result<any ImagePickerResult, any Error>) -> Void)
    private let options: ImageSelectionOptions
    
    init(
        completion: @escaping ((Result<any ImagePickerResult, any Error>) -> Void),
        options: ImageSelectionOptions
    ) {
        self.completion = completion
        self.options = options
    }
    
    @available(macOS 13, *)
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(nil)
        
        if results.isEmpty {
            completion(.success(ImagePickerSuccessResult(filePaths: [])))
            return
        }
        
        var savedFilePaths: [String] = []
        
        Task {
            for result in results {
                let itemProvider = result.itemProvider
                guard itemProvider.hasItemConformingToTypeIdentifier(UTType.heic.identifier) else {
                    completion(.success(ImagePickerErrorResult(error: .invalidImageSelection)))
                    return
                }
                
                var coords: CLLocationCoordinate2D? = nil
                if let assetIdentifier = result.assetIdentifier {
                    let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [assetIdentifier], options: nil)
                    if let asset = fetchResult.firstObject {
                        guard let location = asset.location else {
                            print("No GPS coordinates found for asset.")
                            return
                        }
                        
                        let latitude = location.coordinate.latitude
                        let longitude = location.coordinate.longitude
                        print("GPS Coordinates - Latitude: \(latitude), Longitude: \(longitude)")
                        coords = location.coordinate
                    }
                }
                
                guard
                    let tempImagePath = await PickImageHandler(
                        completion: completion, options: options
                    ).processAndSave(itemProvider: itemProvider, coords: coords)
                else { return }
                savedFilePaths.append(tempImagePath)
            }
            completion(.success(ImagePickerSuccessResult(filePaths: savedFilePaths)))
        }
    }
}

// Currently, multi-video selection is unimplemented.
class PickVideosDelegate: PHPickerViewControllerDelegate {
    private let completion: ((Result<any ImagePickerResult, any Error>) -> Void)
    
    init(completion: @escaping ((Result<any ImagePickerResult, any Error>) -> Void)) {
        self.completion = completion
    }
    
    @available(macOS 13, *)
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(nil)
        
        guard let itemProvider = results.first?.itemProvider else {
            completion(.success(ImagePickerSuccessResult(filePaths: [])))
            return
        }
        
        let canLoadVideo = itemProvider.hasItemConformingToTypeIdentifier(UTType.movie.identifier)
        if !canLoadVideo {
            completion(.success(ImagePickerErrorResult(error: .invalidVideoSelection)))
            return
        }
        
        Task {
            guard
                let tempVideoPath = await PickVideoHandler(completion: completion)
                    .processAndSave(itemProvider: itemProvider)
            else { return }
            
            completion(.success(ImagePickerSuccessResult(filePaths: [tempVideoPath])))
        }
        
    }
}

class PickMediaDelegate: PHPickerViewControllerDelegate {
    private let completion: ((Result<any ImagePickerResult, any Error>) -> Void)
    private let options: MediaSelectionOptions
    
    init(
        completion: @escaping (Result<any ImagePickerResult, any Error>) -> Void,
        options: MediaSelectionOptions
    ) {
        self.completion = completion
        self.options = options
    }
    
    @available(macOS 13, *)
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(nil)
        
        if results.isEmpty {
            completion(.success(ImagePickerSuccessResult(filePaths: [])))
            return
        }
        
        var savedFilePaths: [String] = []
        
        Task {
            for result in results {
                let itemProvider = result.itemProvider
                
                let canLoadImage = itemProvider.hasItemConformingToTypeIdentifier(UTType.heic.identifier)
                if canLoadImage {
                    guard
                        let tempImagePath = await PickImageHandler(
                            completion: completion, options: options.imageSelectionOptions
                        ).processAndSave(itemProvider: itemProvider, coords: nil)
                    else { return }
                    savedFilePaths.append(tempImagePath)
                }
                
                let canLoadVideo = itemProvider.hasItemConformingToTypeIdentifier(UTType.movie.identifier)
                if canLoadVideo {
                    guard
                        let tempVideoPath = await PickVideoHandler(completion: completion).processAndSave(
                            itemProvider: itemProvider)
                    else { return }
                    savedFilePaths.append(tempVideoPath)
                }
            }
            
            completion(.success(ImagePickerSuccessResult(filePaths: savedFilePaths)))
        }
    }
    
}

extension NSItemProvider {
    @available(macOS 13.0, *)
    @MainActor
    func loadFileRepresentation(for contentType: UTType) async throws -> URL {
        return try await withCheckedThrowingContinuation { continuation in
            loadFileRepresentation(for: contentType) { (url, _, error) in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let url = url as? URL {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: NSError(domain: "INVALID_OBJECT", code: -1, userInfo: nil))
                }
            }
        }
    }
    
    @available(macOS 13.0, *)
    @MainActor
    func loadDataRepresentation(for contentType: UTType) async throws -> Data {
        return try await withCheckedThrowingContinuation { continuation in
            loadDataRepresentation(for: contentType) { (data, error) in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let url = data as? Data {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: NSError(domain: "INVALID_OBJECT", code: -1, userInfo: nil))
                }
            }
        }
    }
}

/// Shared image handling between `PickImageDelegate` and `PickMediaDelegate`.
class PickImageHandler {
    let completion: ((Result<any ImagePickerResult, any Error>) -> Void)
    let options: ImageSelectionOptions
    
    init(
        completion: @escaping (Result<any ImagePickerResult, any Error>) -> Void,
        options: ImageSelectionOptions
    ) {
        self.completion = completion
        self.options = options
    }
    
    /// Load an image, process it if needed, copy it to a temporary directory, and return the file path.
    ///
    /// Returns `nil` if an error occurs, and handles.
    @available(macOS 13, *)
    func processAndSave(itemProvider: NSItemProvider, coords: CLLocationCoordinate2D?) async -> String? {
        do {
            let imageData = try await itemProvider.loadDataRepresentation(for: UTType.heic)
            let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".heic")
            
            /*if let latitude = coords?.latitude, let longitude = coords?.longitude {
                let updatedData = try addGPSMetadataToHEIC(data: imageData, latitude: latitude, longitude: longitude)
                try updatedData.write(to: outputURL)
                return outputURL.absoluteString
            }*/
            
            try imageData.write(to: outputURL)
            return outputURL.path()
        } catch {
            completion(
                .success(
                    ImagePickerErrorResult(
                        error: .imageLoadFailed, platformErrorMessage: error.localizedDescription)))
            return nil
        }
    }
    /*
    func addGPSMetadataToHEIC(data: Data, latitude: Double, longitude: Double) throws -> Data {
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
              let uti = CGImageSourceGetType(imageSource),
              let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            throw NSError(domain: "ImageProcessing", code: 1, userInfo: [NSLocalizedDescriptionKey: "Nem sikerült beolvasni a képadatot."])
        }
        
        let originalMetadata = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] ?? [:]
        let location = originalMetadata[kCGImagePropertyGPSDictionary]
        print("Location: \(location)")
        
        var updatedMetadata = originalMetadata
            let gpsDict: [CFString: Any] = [
                kCGImagePropertyGPSLatitude: abs(latitude),
                kCGImagePropertyGPSLatitudeRef: latitude >= 0 ? "N" : "S",
                kCGImagePropertyGPSLongitude: abs(longitude),
                kCGImagePropertyGPSLongitudeRef: longitude >= 0 ? "E" : "W",
                kCGImagePropertyGPSVersion: "2.2.0.0"
            ]
            updatedMetadata[kCGImagePropertyGPSDictionary] = gpsDict

        let outputData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(outputData as CFMutableData, uti, 1, nil) else {
            throw NSError(domain: "ImageProcessing", code: 2, userInfo: [NSLocalizedDescriptionKey: "Nem sikerült létrehozni a kimeneti fájlt."])
        }
        
        CGImageDestinationAddImage(destination, image, updatedMetadata as CFDictionary)
        
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "ImageProcessing", code: 3, userInfo: [NSLocalizedDescriptionKey: "Nem sikerült menteni az új HEIC képet."])
        }
        
        return outputData as Data
    }*/
}

/// Shared image handling between `PickVideosDelegate` and `PickMediaDelegate`.
class PickVideoHandler {
    let completion: ((Result<any ImagePickerResult, any Error>) -> Void)
    
    init(completion: @escaping (Result<any ImagePickerResult, any Error>) -> Void) {
        self.completion = completion
    }
    
    @available(macOS 13.0, *)
    func processAndSave(itemProvider: NSItemProvider) async -> String? {
        do {
            let videoType = UTType.movie
            let tempVideoUrl = try await itemProvider.loadFileRepresentation(for: videoType)
            let tempVideoPath = tempVideoUrl.path()
            return tempVideoPath
        } catch {
            completion(
                .success(
                    ImagePickerErrorResult(
                        error: .videoLoadFailed, platformErrorMessage: error.localizedDescription)))
            return nil
        }
    }
}
