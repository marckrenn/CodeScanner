//
//  TextScannerViewController.swift
//  https://github.com/marckrenn/CodeScanner
//
//  Created by Marc Krenn on 14.03.23.
//

import AVFoundation
import UIKit
import Vision

@available(macCatalyst 14.0, *)
extension TextScannerView {
    
    public class TextScannerViewController: UIViewController, UIImagePickerControllerDelegate, UINavigationControllerDelegate, AVCaptureVideoDataOutputSampleBufferDelegate {
        private let photoOutput = AVCapturePhotoOutput()
        private var isCapturing = true
        private var handler: (() -> Void)?
        var parentView: TextScannerView!
        var stringsFound = Set<String>()
        var didFinishScanning = false
        var lastTime = Date(timeIntervalSince1970: 0)
        private let showViewfinder: Bool
        private var bufferSize = CGSize(width: 0, height: 0)
        let roi = CGRect(origin: CGPoint(x: 0, y: 0.447), size: CGSize(width: 1, height: 0.08))
        
        let validateMatch: (String) -> Bool
        let recognitionLevel: VNRequestTextRecognitionLevel
        let recognitionLanguages: [String]
        let videoSessionPreset: AVCaptureSession.Preset
        let videoSettings: [String : Any]
        
        private var isGalleryShowing: Bool = false {
            didSet {
                // Update binding
                if parentView.isGalleryPresented.wrappedValue != isGalleryShowing {
                    parentView.isGalleryPresented.wrappedValue = isGalleryShowing
                }
            }
        }
        
        public init(
            validateMatch: @escaping (String) -> Bool = { _ in return true },
            recognitionLevel: VNRequestTextRecognitionLevel = .accurate,
            recognitionLanguages: [String] = [],
            videoSessionPreset: AVCaptureSession.Preset = .high,
            videoSettings: [String : Any] = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)],
            showViewfinder: Bool = false,
            parentView: TextScannerView
        ) {
            self.validateMatch = validateMatch
            self.recognitionLevel = recognitionLevel
            self.recognitionLanguages = recognitionLanguages
            self.videoSessionPreset = videoSessionPreset
            self.videoSettings = videoSettings
            self.parentView = parentView
            self.showViewfinder = showViewfinder
            super.init(nibName: nil, bundle: nil)
        }
        
        required init?(coder: NSCoder) {
            self.showViewfinder = false
            self.validateMatch = { _ in return true }
            self.recognitionLevel = .accurate
            self.recognitionLanguages = []
            self.videoSessionPreset = .high
            self.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)]
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
            
            // TODO: Do OCR
            
            //            if let qrcodeImg = info[.originalImage] as? UIImage {
            //                let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])!
            //                let ciImage = CIImage(image:qrcodeImg)!
            //                var qrCodeLink = ""
            //
            //                let features = detector.features(in: ciImage)
            //
            //                for feature in features as! [CIQRCodeFeature] {
            //                    qrCodeLink += feature.messageString!
            //                }
            //
            //                if qrCodeLink == "" {
            //                    didFail(reason: .badOutput)
            //                } else {
            //                    return // TODO: fix
            ////                    let result = TextScanResult(string: qrCodeLink, image: qrcodeImg)
            ////                    found(result)
            //                }
            //            } else {
            //                print("Something went wrong")
            //            }
            
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
            found(TextScanResult(string: parentView.simulatedData))
        }
        
#else
        
        var captureSession: AVCaptureSession?
        var previewLayer: AVCaptureVideoPreviewLayer!
        let fallbackVideoCaptureDevice = AVCaptureDevice.default(for: .video)
        
        var roiQuantatized: CGRect {
            CGRect(x: roi.origin.x * previewLayer.frame.width + previewLayer.frame.origin.x,
                   y: roi.origin.y * previewLayer.frame.height + previewLayer.frame.origin.y,
                   width: roi.size.width * previewLayer.frame.width,
                   height: roi.size.height * previewLayer.frame.height)
        }
        
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
            
//            setupSession()
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
            addRegionOfInterestRect()
            
            reset()
            
            if (captureSession.isRunning == false) {
                DispatchQueue.global(qos: .userInteractive).async {
                    self.captureSession?.startRunning()
                }
            }
        }
        
        private func addRegionOfInterestRect() {
            
            let roiLayer = CAShapeLayer()
            roiLayer.strokeColor = UIColor.red.cgColor
            roiLayer.lineWidth = 2.0
            roiLayer.fillColor = UIColor.clear.cgColor
            roiLayer.path = UIBezierPath(rect: roiQuantatized).cgPath
            
            previewLayer.addSublayer(roiLayer)
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
            captureSession!.sessionPreset = videoSessionPreset
            
            if (captureSession!.canAddInput(videoInput)) {
                captureSession!.addInput(videoInput)
                captureSession!.commitConfiguration()
            } else {
                didFail(reason: .badInput)
                return
            }
            
            let videoDataOutput = AVCaptureVideoDataOutput()
            let videoDataOutputQueue = DispatchQueue(label: "videoDataOutputQueue", attributes: [])
            
            if captureSession!.canAddOutput(videoDataOutput) {
                captureSession!.addOutput(videoDataOutput)
                // Add a video data output
                videoDataOutput.alwaysDiscardsLateVideoFrames = true
                videoDataOutput.videoSettings = videoSettings
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
            if let backCamera = AVCaptureDevice.bestForVideo,
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
            stringsFound.removeAll()
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
            
            func convert(cmage: CIImage) -> UIImage {
                let context = CIContext(options: nil)
                let cgImage = context.createCGImage(cmage, from: cmage.extent)!
                let image = UIImage(cgImage: cgImage)
                return image
            }
            
            let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)!
            let ciimage = CIImage(cvPixelBuffer: imageBuffer).oriented(.left) // TODO: use correct orientation
            let image = convert(cmage: ciimage)
            
            guard let cgImage = image.cgImage else { return }
            
            // Create a new image-request handler.
            let requestHandler = VNImageRequestHandler(cgImage: cgImage)
            
            // Create a new request to recognize text.
            let request = VNRecognizeTextRequest(completionHandler: self.recognizeTextHandler)
            
            request.recognitionLevel = self.recognitionLevel
            request.recognitionLanguages = self.recognitionLanguages
            request.regionOfInterest = roi
            
            do {
                // Perform the text-recognition request.
                if self.isCapturing && !self.didFinishScanning {
                    try requestHandler.perform([request])
                }
                
            } catch {
                print("Unable to perform the requests: \(error).")
            }
            
        }
        
        private func recognizeTextHandler(request: VNRequest, error: Error?) {
            guard let observations = request.results as? [VNRecognizedTextObservation] else { return }
            let recognizedStrings = observations.compactMap { observation in
                return observation.topCandidates(1).first?.string
            }
            
            guard let match = recognizedStrings.first(where: {
                validateMatch($0)
            }) else { return }
            handleResult(stringFound: match)
            return
            
        }
        
        public func handleResult(stringFound: String) {
            
            let result = TextScanResult(string: stringFound)
            
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
                if !stringsFound.contains(stringFound) {
                    stringsFound.insert(stringFound)
                    found(result)
                }
                
            case .continuous:
                if isPastScanInterval() {
                    found(result)
                }
            }
        }
        
        func isPastScanInterval() -> Bool {
            Date().timeIntervalSince(lastTime) >= parentView.scanInterval
        }
        
        func isWithinManualCaptureInterval() -> Bool {
            Date().timeIntervalSince(lastTime) <= 0.5
        }
        
        func found(_ result: TextScanResult) {
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
        //        handler?(qrImage) // TODO
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
