//
//  TextScannerViewController.swift
//  https://github.com/marckrenn/CodeScanner
//
//  Created by Marc Krenn on 14.03.23.
//

import AVFoundation
import UIKit
import Vision

func isAscii(_ str: String) -> Bool {
    for scalar in str.unicodeScalars {
        if scalar.value > 127 { // ASCII characters range from 0 to 127
            return false
        }
    }
    return true
}

func containsLettersAndNumbers(_ str: String) -> Bool {
    let letterCharacterSet = CharacterSet.letters
    let numberCharacterSet = CharacterSet.decimalDigits
    
    let hasLetters = str.rangeOfCharacter(from: letterCharacterSet) != nil
    let hasNumbers = str.rangeOfCharacter(from: numberCharacterSet) != nil
    
    return hasLetters && hasNumbers
}

extension String {
    private func mod97() -> Int {
        let symbols: [Character] = Array(self)
        let swapped = symbols.dropFirst(4) + symbols.prefix(4)
        let mod: Int = swapped.reduce(0) { (previousMod, char) in
            let value = Int(String(char), radix: 36)!
            let factor = value < 10 ? 10 : 100
            let m = (factor * previousMod + value) % 97
            return m
        }
        
        return mod
    }
    
    func isValidIban() -> Bool {
        guard isAscii(self) && containsLettersAndNumbers(self) && self.count > 4 else { return false }

        let uppercase = self.uppercased()
        guard uppercase.range(of: "^[0-9A-Z]*$", options: .regularExpression) != nil else {
            return false
        }
        return (uppercase.mod97() == 1)
    }
}

@available(macCatalyst 14.0, *)
extension TextScannerView {
    
    public class TextScannerViewController: UIViewController, UIImagePickerControllerDelegate, UINavigationControllerDelegate, AVCaptureMetadataOutputObjectsDelegate, AVCaptureVideoDataOutputSampleBufferDelegate {
        private let photoOutput = AVCapturePhotoOutput()
        private var isCapturing = false
        private var handler: ((UIImage) -> Void)?
        var parentView: TextScannerView!
        var codesFound = Set<String>()
        var didFinishScanning = false
        var lastTime = Date(timeIntervalSince1970: 0)
        private let showViewfinder: Bool
        private var bufferSize = CGSize(width: 0, height: 0)
        
        
        private var isGalleryShowing: Bool = false {
            didSet {
                // Update binding
                if parentView.isGalleryPresented.wrappedValue != isGalleryShowing {
                    parentView.isGalleryPresented.wrappedValue = isGalleryShowing
                }
            }
        }
        
        public init(showViewfinder: Bool = false, parentView: TextScannerView) {
            self.parentView = parentView
            self.showViewfinder = showViewfinder
            super.init(nibName: nil, bundle: nil)
        }
        
        required init?(coder: NSCoder) {
            self.showViewfinder = false
            super.init(coder: coder)
        }
        
        func openGallery() {
            isGalleryShowing = true
            let imagePicker = UIImagePickerController()
            imagePicker.delegate = self
            present(imagePicker, animated: true, completion: nil)
        }
        
        @objc func openGalleryFromButton(_ sender: UIButton) {
            openGallery()
        }
        
        public func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            isGalleryShowing = false
            
            if let qrcodeImg = info[.originalImage] as? UIImage {
                let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])!
                let ciImage = CIImage(image:qrcodeImg)!
                var qrCodeLink = ""
                
                let features = detector.features(in: ciImage)
                
                for feature in features as! [CIQRCodeFeature] {
                    qrCodeLink += feature.messageString!
                }
                
                if qrCodeLink == "" {
                    didFail(reason: .badOutput)
                } else {
                    let result = ScanResult(string: qrCodeLink, type: .qr, image: qrcodeImg)
                    found(result)
                }
            } else {
                print("Something went wrong")
            }
            
            dismiss(animated: true, completion: nil)
        }
        
        public func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            isGalleryShowing = false
            dismiss(animated: true, completion: nil)
        }
        
#if targetEnvironment(simulator)
        override public func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = true
            
            let label = UILabel()
            label.translatesAutoresizingMaskIntoConstraints = false
            label.numberOfLines = 0
            label.text = "You're running in the simulator, which means the camera isn't available. Tap anywhere to send back some simulated data."
            label.textAlignment = .center
            
            let button = UIButton()
            button.translatesAutoresizingMaskIntoConstraints = false
            button.setTitle("Select a custom image", for: .normal)
            button.setTitleColor(UIColor.systemBlue, for: .normal)
            button.setTitleColor(UIColor.gray, for: .highlighted)
            button.addTarget(self, action: #selector(openGalleryFromButton), for: .touchUpInside)
            
            let stackView = UIStackView()
            stackView.translatesAutoresizingMaskIntoConstraints = false
            stackView.axis = .vertical
            stackView.spacing = 50
            stackView.addArrangedSubview(label)
            stackView.addArrangedSubview(button)
            
            view.addSubview(stackView)
            
            NSLayoutConstraint.activate([
                button.heightAnchor.constraint(equalToConstant: 50),
                stackView.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
                stackView.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
                stackView.centerYAnchor.constraint(equalTo: view.centerYAnchor)
            ])
        }
        
        override public func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            // Send back their simulated data, as if it was one of the types they were scanning for
            found(ScanResult(
                string: parentView.simulatedData,
                type: parentView.codeTypes.first ?? .qr, image: nil
            ))
        }
        
#else
        
        var captureSession: AVCaptureSession?
        var previewLayer: AVCaptureVideoPreviewLayer!
        let fallbackVideoCaptureDevice = AVCaptureDevice.default(for: .video)
        
        private lazy var viewFinder: UIImageView? = {
            guard let image = UIImage(named: "viewfinder", in: .module, with: nil) else {
                return nil
            }
            
            let imageView = UIImageView(image: image)
            imageView.translatesAutoresizingMaskIntoConstraints = false
            return imageView
        }()
        
        private lazy var manualCaptureButton: UIButton = {
            let button = UIButton(type: .system)
            let image = UIImage(named: "capture", in: .module, with: nil)
            button.setBackgroundImage(image, for: .normal)
            button.addTarget(self, action: #selector(manualCapturePressed), for: .touchUpInside)
            button.translatesAutoresizingMaskIntoConstraints = false
            return button
        }()
        
        private lazy var manualSelectButton: UIButton = {
            let button = UIButton(type: .system)
            let image = UIImage(systemName: "photo.on.rectangle")
            let background = UIImage(systemName: "capsule.fill")?.withTintColor(.systemBackground, renderingMode: .alwaysOriginal)
            button.setImage(image, for: .normal)
            button.setBackgroundImage(background, for: .normal)
            button.addTarget(self, action: #selector(openGalleryFromButton), for: .touchUpInside)
            button.translatesAutoresizingMaskIntoConstraints = false
            return button
        }()
        
        override public func viewDidLoad() {
            super.viewDidLoad()
            self.addOrientationDidChangeObserver()
            self.setBackgroundColor()
            self.handleCameraPermission()
        }
        
        override public func viewWillLayoutSubviews() {
            previewLayer?.frame = view.layer.bounds
        }
        
        @objc func updateOrientation() {
            guard let orientation = view.window?.windowScene?.interfaceOrientation else { return }
            guard let connection = captureSession?.connections.last, connection.isVideoOrientationSupported else { return }
            connection.videoOrientation = AVCaptureVideoOrientation(rawValue: orientation.rawValue) ?? .portrait
        }
        
        override public func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            updateOrientation()
        }
        
        override public func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            
            setupSession()
        }
        
        private func setupSession() {
            guard let captureSession = captureSession else {
                return
            }
            
            if previewLayer == nil {
                previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
            }
            
            previewLayer.frame = view.layer.bounds
            previewLayer.videoGravity = .resizeAspectFill
            view.layer.addSublayer(previewLayer)
            addviewfinder()
            
            reset()
            
            if (captureSession.isRunning == false) {
                DispatchQueue.global(qos: .userInteractive).async {
                    self.captureSession?.startRunning()
                }
            }
        }
        
        private func handleCameraPermission() {
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .restricted:
                break
            case .denied:
                self.didFail(reason: .permissionDenied)
            case .notDetermined:
                self.requestCameraAccess {
                    self.setupCaptureDevice()
                    DispatchQueue.main.async {
                        self.setupSession()
                    }
                }
            case .authorized:
                self.setupCaptureDevice()
                self.setupSession()
                
            default:
                break
            }
        }
        
        private func requestCameraAccess(completion: (() -> Void)?) {
            AVCaptureDevice.requestAccess(for: .video) { [weak self] status in
                guard status else {
                    self?.didFail(reason: .permissionDenied)
                    return
                }
                completion?()
            }
        }
        
        private func addOrientationDidChangeObserver() {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(updateOrientation),
                name: Notification.Name("UIDeviceOrientationDidChangeNotification"),
                object: nil
            )
        }
        
        private func setBackgroundColor(_ color: UIColor = .black) {
            view.backgroundColor = color
        }
        
        private func setupCaptureDevice() {
            captureSession = AVCaptureSession()
            
            guard let videoCaptureDevice = parentView.videoCaptureDevice ?? fallbackVideoCaptureDevice else {
                return
            }
            
            let videoInput: AVCaptureDeviceInput
            
            do {
                videoInput = try AVCaptureDeviceInput(device: videoCaptureDevice)
            } catch {
                didFail(reason: .initError(error))
                return
            }
            
            captureSession!.beginConfiguration()
//            captureSession!.sessionPreset = .hd1920x1080 //.vga640x480 // Model image size is smaller.
            
            if (captureSession!.canAddInput(videoInput)) {
                captureSession!.addInput(videoInput)
                captureSession!.commitConfiguration()
            } else {
                didFail(reason: .badInput)
                return
            }
            
            let videoDataOutput = AVCaptureVideoDataOutput()
            let videoDataOutputQueue = DispatchQueue(label: "sample buffer delegate", attributes: [])
            
            if captureSession!.canAddOutput(videoDataOutput) {
                captureSession!.addOutput(videoDataOutput)
                // Add a video data output
                videoDataOutput.alwaysDiscardsLateVideoFrames = true
                videoDataOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)]
                videoDataOutput.setSampleBufferDelegate(self, queue: videoDataOutputQueue)
            } else {
                didFail(reason: .badOutput)
                return
            }
            
            let captureConnection = videoDataOutput.connection(with: .video)
            // Always process the frames
            captureConnection?.isEnabled = true
            do {
                try videoCaptureDevice.lockForConfiguration()
                let dimensions = CMVideoFormatDescriptionGetDimensions((videoCaptureDevice.activeFormat.formatDescription))
                bufferSize.width = CGFloat(dimensions.width)
                bufferSize.height = CGFloat(dimensions.height)
                videoCaptureDevice.unlockForConfiguration()
            } catch {
                print(error)
            }
            
            captureSession!.commitConfiguration()
            
            //            let metadataOutput = AVCaptureMetadataOutput()
            
            //            if (captureSession!.canAddOutput(metadataOutput)) {
            //                captureSession!.addOutput(metadataOutput)
            //                captureSession?.addOutput(photoOutput)
            //                metadataOutput.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
            //                metadataOutput.metadataObjectTypes = parentView.codeTypes
            //            } else {
            //                didFail(reason: .badOutput)
            //                return
            //            }
        }
        
        private func addviewfinder() {
            guard showViewfinder, let imageView = viewFinder else { return }
            
            view.addSubview(imageView)
            
            NSLayoutConstraint.activate([
                imageView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                imageView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 200),
                imageView.heightAnchor.constraint(equalToConstant: 200),
            ])
        }
        
        override public func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            
            if (captureSession?.isRunning == true) {
                DispatchQueue.global(qos: .userInteractive).async {
                    self.captureSession?.stopRunning()
                }
            }
            
            NotificationCenter.default.removeObserver(self)
        }
        
        override public var prefersStatusBarHidden: Bool {
            true
        }
        
        override public var supportedInterfaceOrientations: UIInterfaceOrientationMask {
            .all
        }
        
        /** Touch the screen for autofocus */
        public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard touches.first?.view == view,
                  let touchPoint = touches.first,
                  let device = parentView.videoCaptureDevice ?? fallbackVideoCaptureDevice,
                  device.isFocusPointOfInterestSupported
            else { return }
            
            let videoView = view
            let screenSize = videoView!.bounds.size
            let xPoint = touchPoint.location(in: videoView).y / screenSize.height
            let yPoint = 1.0 - touchPoint.location(in: videoView).x / screenSize.width
            let focusPoint = CGPoint(x: xPoint, y: yPoint)
            
            do {
                try device.lockForConfiguration()
            } catch {
                return
            }
            
            // Focus to the correct point, make continiuous focus and exposure so the point stays sharp when moving the device closer
            device.focusPointOfInterest = focusPoint
            device.focusMode = .continuousAutoFocus
            device.exposurePointOfInterest = focusPoint
            device.exposureMode = AVCaptureDevice.ExposureMode.continuousAutoExposure
            device.unlockForConfiguration()
        }
        
        @objc func manualCapturePressed(_ sender: Any?) {
            self.readyManualCapture()
        }
        
        func showManualCaptureButton(_ isManualCapture: Bool) {
            if manualCaptureButton.superview == nil {
                view.addSubview(manualCaptureButton)
                NSLayoutConstraint.activate([
                    manualCaptureButton.heightAnchor.constraint(equalToConstant: 60),
                    manualCaptureButton.widthAnchor.constraint(equalTo: manualCaptureButton.heightAnchor),
                    view.centerXAnchor.constraint(equalTo: manualCaptureButton.centerXAnchor),
                    view.safeAreaLayoutGuide.bottomAnchor.constraint(equalTo: manualCaptureButton.bottomAnchor, constant: 32)
                ])
            }
            
            view.bringSubviewToFront(manualCaptureButton)
            manualCaptureButton.isHidden = !isManualCapture
        }
        
        func showManualSelectButton(_ isManualSelect: Bool) {
            if manualSelectButton.superview == nil {
                view.addSubview(manualSelectButton)
                NSLayoutConstraint.activate([
                    manualSelectButton.heightAnchor.constraint(equalToConstant: 50),
                    manualSelectButton.widthAnchor.constraint(equalToConstant: 60),
                    view.centerXAnchor.constraint(equalTo: manualSelectButton.centerXAnchor),
                    view.safeAreaLayoutGuide.bottomAnchor.constraint(equalTo: manualSelectButton.bottomAnchor, constant: 32)
                ])
            }
            
            view.bringSubviewToFront(manualSelectButton)
            manualSelectButton.isHidden = !isManualSelect
        }
#endif
        
        func updateViewController(isTorchOn: Bool, isGalleryPresented: Bool, isManualCapture: Bool, isManualSelect: Bool) {
            if let backCamera = AVCaptureDevice.default(for: AVMediaType.video),
               backCamera.hasTorch
            {
                try? backCamera.lockForConfiguration()
                backCamera.torchMode = isTorchOn ? .on : .off
                backCamera.unlockForConfiguration()
            }
            
            if isGalleryPresented && !isGalleryShowing {
                openGallery()
            }
            
#if !targetEnvironment(simulator)
            showManualCaptureButton(isManualCapture)
            showManualSelectButton(isManualSelect)
#endif
        }
        
        public func reset() {
            codesFound.removeAll()
            didFinishScanning = false
            lastTime = Date(timeIntervalSince1970: 0)
        }
        
        public func readyManualCapture() {
            guard parentView.scanMode == .manual else { return }
            self.reset()
            lastTime = Date()
        }
        
        public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection
        ) {
            //            print(Date().description(with: .autoupdatingCurrent))
            let curDeviceOrientation = UIDevice.current.orientation
            let exifOrientation: CGImagePropertyOrientation
            
            switch curDeviceOrientation {
            case UIDeviceOrientation.portraitUpsideDown:  // Device oriented vertically, home button on the top
                exifOrientation = .left
            case UIDeviceOrientation.landscapeLeft:       // Device oriented horizontally, home button on the right
                exifOrientation = .upMirrored
            case UIDeviceOrientation.landscapeRight:      // Device oriented horizontally, home button on the left
                exifOrientation = .down
            case UIDeviceOrientation.portrait:            // Device oriented vertically, home button on the bottom
                exifOrientation = .up
            default:
                exifOrientation = .up
            }
            
            
//            let cgImage = getImageFromSampleBuffer(sampleBuffer: sampleBuffer)
            
            func convert(cmage: CIImage) -> UIImage {
                 let context = CIContext(options: nil)
                 let cgImage = context.createCGImage(cmage, from: cmage.extent)!
                 let image = UIImage(cgImage: cgImage)
                 return image
            }
            
            DispatchQueue.main.async {
                let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)!
                let ciimage = CIImage(cvPixelBuffer: imageBuffer)
                let image = convert(cmage: ciimage)
                
                guard let cgImage = image.cgImage else { return }
   
                //                self.imageView.image = image


                // Create a new image-request handler.
                let requestHandler = VNImageRequestHandler(cgImage: cgImage)

                // Create a new request to recognize text.
                let request = VNRecognizeTextRequest(completionHandler: self.recognizeTextHandler)
                request.recognitionLevel = .accurate

                do {
                    // Perform the text-recognition request.
                    try requestHandler.perform([request])
                } catch {
                    print("Unable to perform the requests: \(error).")
                }
                
            }
        }
        
        private func recognizeTextHandler(request: VNRequest, error: Error?) {
            guard let observations = request.results as? [VNRecognizedTextObservation] else {
                return
            }
            let recognizedStrings = observations.compactMap { observation in
                return observation.topCandidates(1).first?.string
            }
            
            recognizedStrings.forEach {
                if $0.isValidIban() {
                    print($0)
                }
            }
        }
        
        public func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
            if let metadataObject = metadataObjects.first {
                guard let readableObject = metadataObject as? AVMetadataMachineReadableCodeObject else { return }
                guard let stringValue = readableObject.stringValue else { return }
                
                guard didFinishScanning == false else { return }
                
                let photoSettings = AVCapturePhotoSettings()
                guard !isCapturing else { return }
                isCapturing = true
                
                handler = { [self] image in
                    let result = ScanResult(string: stringValue, type: readableObject.type, image: image)
                    
                    switch parentView.scanMode {
                    case .once:
                        found(result)
                        // make sure we only trigger scan once per use
                        didFinishScanning = true
                        
                    case .manual:
                        if !didFinishScanning, isWithinManualCaptureInterval() {
                            found(result)
                            didFinishScanning = true
                        }
                        
                    case .oncePerCode:
                        if !codesFound.contains(stringValue) {
                            codesFound.insert(stringValue)
                            found(result)
                        }
                        
                    case .continuous:
                        if isPastScanInterval() {
                            found(result)
                        }
                    }
                }
                photoOutput.capturePhoto(with: photoSettings, delegate: self)
            }
        }
        
        func isPastScanInterval() -> Bool {
            Date().timeIntervalSince(lastTime) >= parentView.scanInterval
        }
        
        func isWithinManualCaptureInterval() -> Bool {
            Date().timeIntervalSince(lastTime) <= 0.5
        }
        
        func found(_ result: ScanResult) {
            lastTime = Date()
            
            if parentView.shouldVibrateOnSuccess {
                AudioServicesPlaySystemSound(SystemSoundID(kSystemSoundID_Vibrate))
            }
            
            parentView.completion(.success(result))
        }
        
        func didFail(reason: ScanError) {
            parentView.completion(.failure(reason))
        }
        
    }
}

@available(macCatalyst 14.0, *)
extension TextScannerView.TextScannerViewController: AVCapturePhotoCaptureDelegate {
    
    public func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        isCapturing = false
        guard let imageData = photo.fileDataRepresentation() else {
            print("Error while generating image from photo capture data.");
            return
        }
        guard let qrImage = UIImage(data: imageData) else {
            print("Unable to generate UIImage from image data.");
            return
        }
        handler?(qrImage)
    }
    
    public func photoOutput(
        _ output: AVCapturePhotoOutput,
        willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings
    ) {
        AudioServicesDisposeSystemSoundID(1108)
    }
    
    public func photoOutput(
        _ output: AVCapturePhotoOutput,
        didCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings
    ) {
        AudioServicesDisposeSystemSoundID(1108)
    }
    
}

//@available(macCatalyst 14.0, *)
//public extension AVCaptureDevice {
//    
//    /// This returns the Ultra Wide Camera on capable devices and the default Camera for Video otherwise.
//    static var bestForVideo: AVCaptureDevice? {
//        let deviceHasUltraWideCamera = !AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInUltraWideCamera], mediaType: .video, position: .back).devices.isEmpty
//        return deviceHasUltraWideCamera ? AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back) : AVCaptureDevice.default(for: .video)
//    }
//    
//}

