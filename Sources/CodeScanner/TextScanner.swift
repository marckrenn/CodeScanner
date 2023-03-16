//
//  TextScanner.swift
//  https://github.com/marckrenn/CodeScanner
//
//  Created by Marc Krenn on 14.03.23.
//

import AVFoundation
import SwiftUI
import Vision

/// An enum describing the ways CodeScannerView can hit scanning problems.
public enum TextScanError: Error {
    /// The camera could not be accessed.
    case badInput

    /// The camera was not capable of scanning the requested codes.
    case badOutput

    /// Initialization failed.
    case initError(_ error: Error)
  
    /// The camera permission is denied
    case permissionDenied
}

/// The result from a successful scan: the string that was scanned, and also the type of data that was found.
/// The type is useful for times when you've asked to scan several different code types at the same time, because
/// it will report the exact code type that was found.
@available(macCatalyst 14.0, *)
public struct TextScanResult {
    /// The matching String.
    public let string: String
}

/// The operating mode for CodeScannerView.
public enum TextScanMode {
    /// Scan exactly one code, then stop.
    case once

    /// Scan each code no more than once.
    case oncePerCode

    /// Keep scanning all codes until dismissed.
    case continuous

    /// Scan only when capture button is tapped.
    case manual
}

/// A SwiftUI view that is able to scan barcodes, QR codes, and more, and send back what was found.
/// To use, set `codeTypes` to be an array of things to scan for, e.g. `[.qr]`, and set `completion` to
/// a closure that will be called when scanning has finished. This will be sent the string that was detected or a `ScanError`.
/// For testing inside the simulator, set the `simulatedData` property to some test data you want to send back.
@available(macCatalyst 14.0, *)
public struct TextScannerView: UIViewControllerRepresentable {
    
    public let validateMatch: (String) -> Bool
    public let preProcessMatches: (String) -> String
    public let recognitionLevel: VNRequestTextRecognitionLevel
    public let recognitionLanguages: [String]
    public let scanMode: ScanMode
    public let manualSelect: Bool
    public let scanInterval: Double
    public let showViewfinder: Bool
    public var simulatedData = ""
    public var shouldVibrateOnSuccess: Bool
    public var isTorchOn: Bool
    public var isGalleryPresented: Binding<Bool>
    public var videoCaptureDevice: AVCaptureDevice?
    public let videoSessionPreset: AVCaptureSession.Preset
    public let videoSettings: [String : Any]
    public var completion: (Result<TextScanResult, ScanError>) -> Void

    public init(
        validateMatch: @escaping (String) -> Bool = { _ in return true },
        preProcessMatches: @escaping (String) -> String = { return $0 },
        recognitionLevel: VNRequestTextRecognitionLevel = .accurate,
        recognitionLanguages: [String] = [],
        scanMode: ScanMode = .once,
        manualSelect: Bool = false,
        scanInterval: Double = 2.0,
        showViewfinder: Bool = false,
        simulatedData: String = "",
        shouldVibrateOnSuccess: Bool = true,
        isTorchOn: Bool = false,
        isGalleryPresented: Binding<Bool> = .constant(false),
        videoCaptureDevice: AVCaptureDevice? = AVCaptureDevice.bestForVideo,
        videoSessionPreset: AVCaptureSession.Preset = .high,
        videoSettings: [String : Any] = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)],
        completion: @escaping (Result<TextScanResult, ScanError>) -> Void
    ) {
        self.validateMatch = validateMatch
        self.preProcessMatches = preProcessMatches
        self.recognitionLevel = recognitionLevel
        self.recognitionLanguages = recognitionLanguages
        self.scanMode = scanMode
        self.manualSelect = manualSelect
        self.showViewfinder = showViewfinder
        self.scanInterval = scanInterval
        self.simulatedData = simulatedData
        self.shouldVibrateOnSuccess = shouldVibrateOnSuccess
        self.isTorchOn = isTorchOn
        self.isGalleryPresented = isGalleryPresented
        self.videoCaptureDevice = videoCaptureDevice
        self.videoSessionPreset = videoSessionPreset
        self.videoSettings = videoSettings
        self.completion = completion
    }

    public func makeUIViewController(context: Context) -> TextScannerViewController {
        return TextScannerViewController(validateMatch: validateMatch,
                                         preProcessMatches: preProcessMatches,
                                         recognitionLevel: recognitionLevel,
                                         recognitionLanguages: recognitionLanguages,
                                         videoSessionPreset: videoSessionPreset,
                                         videoSettings: videoSettings,
                                         showViewfinder: showViewfinder,
                                         parentView: self)
    }

    public func updateUIViewController(_ uiViewController: TextScannerViewController, context: Context) {
        uiViewController.parentView = self
        uiViewController.updateViewController(
            isTorchOn: isTorchOn,
            isGalleryPresented: isGalleryPresented.wrappedValue,
            isManualCapture: scanMode == .manual,
            isManualSelect: manualSelect
        )
    }
    
}

@available(macCatalyst 14.0, *)
struct TextScannerView_Previews: PreviewProvider {
    static var previews: some View {
        TextScannerView() { result in
            // do nothing
        }
    }
}
