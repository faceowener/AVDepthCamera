/*
See LICENSE.txt for this sample’s licensing information.

Abstract:
View controller for camera interface.
*/

import UIKit
import AVFoundation
import CoreVideo
import Photos
import VideoToolbox
import MobileCoreServices

@available(iOS 11.1, *)
class CameraViewController: UIViewController, AVCapturePhotoCaptureDelegate, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureDepthDataOutputDelegate, AVCaptureDataOutputSynchronizerDelegate {

	// MARK: - Properties
    
    private var recordButton: UIButton!
	@IBOutlet weak private var photoButton: UIButton!
	@IBOutlet weak private var resumeButton: UIButton!
	@IBOutlet weak private var cameraUnavailableLabel: UILabel!
	@IBOutlet weak private var previewView: PreviewMetalView!

	private enum SessionSetupResult {
		case success
		case notAuthorized
		case configurationFailed
	}

	private var setupResult: SessionSetupResult = .success

	private let session = AVCaptureSession()

	private var isSessionRunning = false
    private var isContinousCapture = false

	// Communicate with the session and other session objects on this queue.
	private let sessionQueue = DispatchQueue(label: "session queue", attributes: [], autoreleaseFrequency: .workItem)

	private var videoDeviceInput: AVCaptureDeviceInput!

	private let dataOutputQueue = DispatchQueue(label: "video data queue", qos: .userInitiated, attributes: [], autoreleaseFrequency: .workItem)

	private let videoDataOutput = AVCaptureVideoDataOutput()
	private let depthDataOutput = AVCaptureDepthDataOutput()
	private var outputSynchronizer: AVCaptureDataOutputSynchronizer?
	private let photoOutput = AVCapturePhotoOutput()

	private let filterRenderers: [FilterRenderer] = [RosyMetalRenderer(), RosyCIRenderer()]
	private let photoRenderers: [FilterRenderer] = [RosyMetalRenderer(), RosyCIRenderer()]

	private let videoDepthMixer = VideoMixer()
	private let photoDepthMixer = VideoMixer()
	private var videoFilter: FilterRenderer?
	private var photoFilter: FilterRenderer?

	private let videoDepthConverter = DepthToGrayscaleConverter()
	private let photoDepthConverter = DepthToGrayscaleConverter()

	private var currentDepthPixelBuffer: CVPixelBuffer?

	private var renderingEnabled = true
	private var depthVisualizationEnabled = true
    private var recordingEnabled = false
    private var recordingRGBPerFrameFinished = false
    private var recordingDepthPerFrameFinished = false
    private var isShowRGBRawData = false
    
    private var totalTimeIntervalForDepth = 0.0 as Double
    private var totalTimeIntervalForRGB = 0.0 as Double

	private let processingQueue = DispatchQueue(label: "photo processing queue", attributes: [], autoreleaseFrequency: .workItem)

	private let videoDeviceDiscoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInTrueDepthCamera],mediaType: .video,position: .front)

	private var statusBarOrientation: UIInterfaceOrientation = .portrait
    
    private var currentTime:String{
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMddHHmmssSSSS"
        let time = formatter.string(from: NSDate() as Date)
        return time;
    }
    
    // MARK: - File Manager
    
    private func createFolder(folderName:String) {
        let documentsPath = NSURL(fileURLWithPath: NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0])
        let logsPath = documentsPath.appendingPathComponent(folderName)
        print(logsPath!)
        do {
            try FileManager.default.createDirectory(atPath: logsPath!.path, withIntermediateDirectories: true, attributes: nil)
        } catch let error as NSError {
            print("Unable to create directory \(error.debugDescription)")
        }
    }
    
    private func getFolderPath(imagePath:String)->String {
        let documentsPath = NSURL(fileURLWithPath: NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0])
        var finalPath = documentsPath.absoluteString
        finalPath?.append(imagePath)
        return finalPath!
    }
    
	// MARK: - View Controller Life Cycle

	override func viewDidLoad() {
		super.viewDidLoad()
        
        self.createFolder(folderName: "RGBImages")
        self.createFolder(folderName: "DepthImages")
        
		// Disable UI. The UI is enabled if and only if the session starts running.
		photoButton.isEnabled = false

		let tapGesture = UITapGestureRecognizer(target: self, action: #selector(focusAndExposeTap))
		previewView.addGestureRecognizer(tapGesture)

		// Check video authorization status, video access is required
		switch AVCaptureDevice.authorizationStatus(for: .video) {
			case .authorized:
				break
			case .notDetermined:
				sessionQueue.suspend()
				AVCaptureDevice.requestAccess(for: .video, completionHandler: { granted in
					if !granted {
						self.setupResult = .notAuthorized
					}
					self.sessionQueue.resume()
				})
			default:
				setupResult = .notAuthorized
		}
		sessionQueue.async {
			self.configureSession()
		}
        
        self.recordButton = UIButton()
        self.recordButton.frame = CGRect(x:self.view.frame.size.width-90, y:self.view.frame.size.height-83, width:80, height:30)
        self.recordButton.backgroundColor = UIColor.clear
        self.recordButton.setTitleColor(UIColor.yellow, for: .normal)
        self.recordButton.setTitle("Start", for: UIControlState.normal)
        self.recordButton.addTarget(self, action: #selector(startRecord), for: .touchUpInside)

        self.previewView.addSubview(self.recordButton)
	}
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        self.configDepthEnabled()
    }

	override func viewWillAppear(_ animated: Bool) {
		super.viewWillAppear(animated)

		let interfaceOrientation = UIApplication.shared.statusBarOrientation
		statusBarOrientation = interfaceOrientation

		let initialThermalState = ProcessInfo.processInfo.thermalState
		if initialThermalState == .serious || initialThermalState == .critical {
			showThermalState(state: initialThermalState)
		}

		sessionQueue.async {
			switch self.setupResult {
				case .success:
					// Only setup observers and start the session running if setup succeeded
					self.addObservers()
					if let photoOrientation = interfaceOrientation.videoOrientation {
						self.photoOutput.connection(with: .video)!.videoOrientation = photoOrientation
					}
					let videoOrientation = self.videoDataOutput.connection(with: .video)!.videoOrientation
					let videoDevicePosition = self.videoDeviceInput.device.position
					let rotation = PreviewMetalView.Rotation(with: interfaceOrientation, videoOrientation: videoOrientation, cameraPosition: videoDevicePosition)
					self.previewView.mirroring = (videoDevicePosition == .front)
					if let rotation = rotation {
						self.previewView.rotation = rotation
					}
					self.dataOutputQueue.async {
						self.renderingEnabled = true
					}

					self.session.startRunning()
					self.isSessionRunning = self.session.isRunning

				case .notAuthorized:
					DispatchQueue.main.async {
						let message = NSLocalizedString("AVDepthCamera doesn't have permission to use the camera, please change privacy settings",
						                                comment: "Alert message when the user has denied access to the camera")
						let alertController = UIAlertController(title: "AVDepthCamera", message: message, preferredStyle: .alert)
						alertController.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: "Alert OK button"),
						                                        style: .cancel,
						                                        handler: nil))
						alertController.addAction(UIAlertAction(title: NSLocalizedString("Settings", comment: "Alert button to open Settings"),
						                                        style: .`default`,
						                                        handler: { _ in
																	UIApplication.shared.open(URL(string: UIApplicationOpenSettingsURLString)!,
																	                          options: [:],
																	                          completionHandler: nil)
						}))

						self.present(alertController, animated: true, completion: nil)
					}

				case .configurationFailed:
					DispatchQueue.main.async {
						let message = NSLocalizedString("Unable to capture media", comment: "Alert message when something goes wrong during capture session configuration")
						let alertController = UIAlertController(title: "AVDepthCamera", message: message, preferredStyle: .alert)
						alertController.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: "Alert OK button"), style: .cancel, handler: nil))

						self.present(alertController, animated: true, completion: nil)
					}
			}
		}
	}

	override func viewWillDisappear(_ animated: Bool) {
		dataOutputQueue.async {
			self.renderingEnabled = false
		}
		sessionQueue.async {
			if self.setupResult == .success {
				self.session.stopRunning()
				self.isSessionRunning = self.session.isRunning
				self.removeObservers()
			}
		}

		super.viewWillDisappear(animated)
	}

@objc
	func didEnterBackground(notification: NSNotification) {
		// Free up resources
		dataOutputQueue.async {
			self.renderingEnabled = false
			if let videoFilter = self.videoFilter {
				videoFilter.reset()
			}
			self.videoDepthMixer.reset()
			self.currentDepthPixelBuffer = nil
			self.videoDepthConverter.reset()
			self.previewView.pixelBuffer = nil
			self.previewView.flushTextureCache()
		}
		processingQueue.async {
			if let photoFilter = self.photoFilter {
				photoFilter.reset()
			}
			self.photoDepthMixer.reset()
			self.photoDepthConverter.reset()
		}
	}

@objc
	func willEnterForground(notification: NSNotification) {
		dataOutputQueue.async {
			self.renderingEnabled = true
		}
	}

	// You can use this opportunity to take corrective action to help cool the system down.
@objc
	func thermalStateChanged(notification: NSNotification) {
		if let processInfo = notification.object as? ProcessInfo {
			showThermalState(state: processInfo.thermalState)
		}
	}

	func showThermalState(state: ProcessInfo.ThermalState) {
		DispatchQueue.main.async {
			var thermalStateString = "UNKNOWN"
			if state == .nominal {
				thermalStateString = "NOMINAL"
			} else if state == .fair {
				thermalStateString = "FAIR"
			} else if state == .serious {
				thermalStateString = "SERIOUS"
			} else if state == .critical {
				thermalStateString = "CRITICAL"
			}

			let message = NSLocalizedString("Thermal state: \(thermalStateString)", comment: "Alert message when thermal state has changed")
			let alertController = UIAlertController(title: "AVDepthCamera", message: message, preferredStyle: .alert)
			alertController.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: "Alert OK button"), style: .cancel, handler: nil))
			self.present(alertController, animated: true, completion: nil)
		}
	}

	override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
		return .all
	}

	override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
		super.viewWillTransition(to: size, with: coordinator)

		coordinator.animate(
			alongsideTransition: { _ in
				let interfaceOrientation = UIApplication.shared.statusBarOrientation
				self.statusBarOrientation = interfaceOrientation
				self.sessionQueue.async {
					/*
						The photo orientation is based on the interface orientation. You could also set the orientation of the photo connection based
						on the device orientation by observing UIDeviceOrientationDidChangeNotification.
					*/
					if let photoOrientation = interfaceOrientation.videoOrientation {
						self.photoOutput.connection(with: .video)!.videoOrientation = photoOrientation
					}
					let videoOrientation = self.videoDataOutput.connection(with: .video)!.videoOrientation
					if let rotation = PreviewMetalView.Rotation(with: interfaceOrientation, videoOrientation: videoOrientation, cameraPosition: self.videoDeviceInput.device.position) {
						self.previewView.rotation = rotation
					}
				}
			}, completion: nil
		)
	}

	// MARK: - KVO and Notifications

	private var sessionRunningContext = 0

	private func addObservers() {
		NotificationCenter.default.addObserver(self, selector: #selector(didEnterBackground), name: NSNotification.Name.UIApplicationDidEnterBackground, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(willEnterForground), name: NSNotification.Name.UIApplicationWillEnterForeground, object: nil)
		//NotificationCenter.default.addObserver(self, selector: #selector(thermalStateChanged), name: ProcessInfo.thermalStateDidChangeNotification,	object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(sessionRuntimeError), name: NSNotification.Name.AVCaptureSessionRuntimeError, object: session)

		session.addObserver(self, forKeyPath: "running", options: NSKeyValueObservingOptions.new, context: &sessionRunningContext)

		/*
			A session can only run when the app is full screen. It will be interrupted
			in a multi-app layout, introduced in iOS 9, see also the documentation of
			AVCaptureSessionInterruptionReason. Add observers to handle these session
			interruptions and show a preview is paused message. See the documentation
			of AVCaptureSessionWasInterruptedNotification for other interruption reasons.
		*/
		NotificationCenter.default.addObserver(self, selector: #selector(sessionWasInterrupted), name: NSNotification.Name.AVCaptureSessionWasInterrupted, object: session)
		NotificationCenter.default.addObserver(self, selector: #selector(sessionInterruptionEnded), name: NSNotification.Name.AVCaptureSessionInterruptionEnded, object: session)
		NotificationCenter.default.addObserver(self, selector: #selector(subjectAreaDidChange), name: NSNotification.Name.AVCaptureDeviceSubjectAreaDidChange, object: videoDeviceInput.device)
	}

	private func removeObservers() {
		NotificationCenter.default.removeObserver(self)
		session.removeObserver(self, forKeyPath: "running", context: &sessionRunningContext)
	}

	override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
		if context == &sessionRunningContext {
			let newValue = change?[.newKey] as AnyObject?
			guard let isSessionRunning = newValue?.boolValue else { return }
			DispatchQueue.main.async {
				self.photoButton.isEnabled = isSessionRunning
			}
		} else {
			super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
		}
	}

	// MARK: - Session Management

	// Call this on the session queue
	private func configureSession() {
		if setupResult != .success {
			return
		}

		let defaultVideoDevice: AVCaptureDevice? = videoDeviceDiscoverySession.devices.first

		guard let videoDevice = defaultVideoDevice else {
			print("Could not find any video device")
			setupResult = .configurationFailed
			return
		}

		do {
			videoDeviceInput = try AVCaptureDeviceInput(device: videoDevice)
		} catch {
			print("Could not create video device input: \(error)")
			setupResult = .configurationFailed
			return
		}

		session.beginConfiguration()
		session.sessionPreset = AVCaptureSession.Preset.hd1280x720

		// Add a video input
		guard session.canAddInput(videoDeviceInput) else {
			print("Could not add video device input to the session")
			setupResult = .configurationFailed
			session.commitConfiguration()
			return
		}
		session.addInput(videoDeviceInput)

		// Add a video data output
		if session.canAddOutput(videoDataOutput) {
			session.addOutput(videoDataOutput)
			videoDataOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
			videoDataOutput.setSampleBufferDelegate(self, queue: dataOutputQueue)
		} else {
			print("Could not add video data output to the session")
			setupResult = .configurationFailed
			session.commitConfiguration()
			return
		}

		// Add photo output
		if session.canAddOutput(photoOutput) {
			session.addOutput(photoOutput)

			photoOutput.isHighResolutionCaptureEnabled = true

			if depthVisualizationEnabled {
				if photoOutput.isDepthDataDeliverySupported {
					photoOutput.isDepthDataDeliveryEnabled = true
				} else {
					depthVisualizationEnabled = false
				}
			}

		} else {
			print("Could not add photo output to the session")
			setupResult = .configurationFailed
			session.commitConfiguration()
			return
		}

		// Add a depth data output
		if session.canAddOutput(depthDataOutput) {
			session.addOutput(depthDataOutput)
			depthDataOutput.setDelegate(self, callbackQueue: dataOutputQueue)
			depthDataOutput.isFilteringEnabled = true
            if let connection = depthDataOutput.connection(with: .depthData) {
                connection.isEnabled = depthVisualizationEnabled
            } else {
                print("No AVCaptureConnection")
            }
		} else {
			print("Could not add depth data output to the session")
			setupResult = .configurationFailed
			session.commitConfiguration()
			return
		}

		if depthVisualizationEnabled {
			// Use an AVCaptureDataOutputSynchronizer to synchronize the video data and depth data outputs.
			// The first output in the dataOutputs array, in this case the AVCaptureVideoDataOutput, is the "master" output.
			outputSynchronizer = AVCaptureDataOutputSynchronizer(dataOutputs: [videoDataOutput, depthDataOutput])
			outputSynchronizer!.setDelegate(self, queue: dataOutputQueue)
		} else {
			outputSynchronizer = nil
		}

		if self.photoOutput.isDepthDataDeliverySupported {
			// Cap the video framerate at the max depth framerate
			if let frameDuration = videoDevice.activeDepthDataFormat?.videoSupportedFrameRateRanges.first?.minFrameDuration {
				do {
					try videoDevice.lockForConfiguration()
					videoDevice.activeVideoMinFrameDuration = frameDuration
					videoDevice.unlockForConfiguration()
				} catch {
					print("Could not lock device for configuration: \(error)")
				}
			}
		}

		session.commitConfiguration()
	}

	private func focus(with focusMode: AVCaptureDevice.FocusMode, exposureMode: AVCaptureDevice.ExposureMode, at devicePoint: CGPoint, monitorSubjectAreaChange: Bool) {
		sessionQueue.async {
			let videoDevice = self.videoDeviceInput.device

			do {
				try videoDevice.lockForConfiguration()
				if videoDevice.isFocusPointOfInterestSupported && videoDevice.isFocusModeSupported(focusMode) {
					videoDevice.focusPointOfInterest = devicePoint
					videoDevice.focusMode = focusMode
				}

				if videoDevice.isExposurePointOfInterestSupported && videoDevice.isExposureModeSupported(exposureMode) {
					videoDevice.exposurePointOfInterest = devicePoint
					videoDevice.exposureMode = exposureMode
				}

				videoDevice.isSubjectAreaChangeMonitoringEnabled = monitorSubjectAreaChange
				videoDevice.unlockForConfiguration()
			} catch {
				print("Could not lock device for configuration: \(error)")
			}
		}
	}
    
	func configDepthEnabled() {
		var depthEnabled = true

		sessionQueue.async {
			self.session.beginConfiguration()

			if self.photoOutput.isDepthDataDeliverySupported {
				self.photoOutput.isDepthDataDeliveryEnabled = depthEnabled
			} else {
				depthEnabled = false
			}

			self.depthDataOutput.connection(with: .depthData)!.isEnabled = depthEnabled

			if depthEnabled {
				// Use an AVCaptureDataOutputSynchronizer to synchronize the video data and depth data outputs.
				// The first output in the dataOutputs array, in this case the AVCaptureVideoDataOutput, is the "master" output.
				self.outputSynchronizer = AVCaptureDataOutputSynchronizer(dataOutputs: [self.videoDataOutput, self.depthDataOutput])
				self.outputSynchronizer!.setDelegate(self, queue: self.dataOutputQueue)
			} else {
				self.outputSynchronizer = nil
			}

			self.session.commitConfiguration()

			self.dataOutputQueue.async {
				if !depthEnabled {
					self.videoDepthConverter.reset()
					self.videoDepthMixer.reset()
					self.currentDepthPixelBuffer = nil
				}
				self.depthVisualizationEnabled = depthEnabled
			}

			self.processingQueue.async {
				if !depthEnabled {
					self.photoDepthMixer.reset()
					self.photoDepthConverter.reset()
				}
			}
		}
	}

	@IBAction private func focusAndExposeTap(_ gesture: UITapGestureRecognizer) {
        
        dataOutputQueue.async {
            if self.videoDepthMixer.mixFactor == 1.0 {
                self.videoDepthMixer.mixFactor = 0.0
            }else{
                self.videoDepthMixer.mixFactor = 1.0
            }
        }

        
		/*let location = gesture.location(in: previewView)
		guard let texturePoint = previewView.texturePointForView(point: location) else {
			return
		}

		let textureRect = CGRect(origin: texturePoint, size: .zero)
		let deviceRect = videoDataOutput.metadataOutputRectConverted(fromOutputRect: textureRect)
		focus(with: .autoFocus, exposureMode: .autoExpose, at: deviceRect.origin, monitorSubjectAreaChange: true)*/
	}

@objc
	func subjectAreaDidChange(notification: NSNotification) {
		let devicePoint = CGPoint(x: 0.5, y: 0.5)
		focus(with: .continuousAutoFocus, exposureMode: .continuousAutoExposure, at: devicePoint, monitorSubjectAreaChange: false)
	}

@objc
	func sessionWasInterrupted(notification: NSNotification) {
		// In iOS 9 and later, the userInfo dictionary contains information on why the session was interrupted.
		if let userInfoValue = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as AnyObject?,
			let reasonIntegerValue = userInfoValue.integerValue,
			let reason = AVCaptureSession.InterruptionReason(rawValue: reasonIntegerValue) {
			print("Capture session was interrupted with reason \(reason)")

			if reason == .videoDeviceInUseByAnotherClient {
				// Simply fade-in a button to enable the user to try to resume the session running.
				resumeButton.isHidden = false
				resumeButton.alpha = 0.0
				UIView.animate(withDuration: 0.25) {
					self.resumeButton.alpha = 1.0
				}
			} else if reason == .videoDeviceNotAvailableWithMultipleForegroundApps {
				// Simply fade-in a label to inform the user that the camera is unavailable.
				cameraUnavailableLabel.isHidden = false
				cameraUnavailableLabel.alpha = 0.0
				UIView.animate(withDuration: 0.25) {
					self.cameraUnavailableLabel.alpha = 1.0
				}
			}
		}
	}

@objc
	func sessionInterruptionEnded(notification: NSNotification) {
		if !resumeButton.isHidden {
			UIView.animate(withDuration: 0.25,
				animations: {
					self.resumeButton.alpha = 0
				}, completion: { _ in
					self.resumeButton.isHidden = true
				}
			)
		}
		if !cameraUnavailableLabel.isHidden {
			UIView.animate(withDuration: 0.25,
				animations: {
					self.cameraUnavailableLabel.alpha = 0
				}, completion: { _ in
					self.cameraUnavailableLabel.isHidden = true
				}
			)
		}
	}

@objc
	func sessionRuntimeError(notification: NSNotification) {
		guard let errorValue = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError else {
			return
		}

		let error = AVError(_nsError: errorValue)
		print("Capture session runtime error: \(error)")

		/*
			Automatically try to restart the session running if media services were
			reset and the last start running succeeded. Otherwise, enable the user
			to try to resume the session running.
		*/
		if error.code == .mediaServicesWereReset {
			sessionQueue.async {
				if self.isSessionRunning {
					self.session.startRunning()
					self.isSessionRunning = self.session.isRunning
				} else {
					DispatchQueue.main.async {
						self.resumeButton.isHidden = false
					}
				}
			}
		} else {
			resumeButton.isHidden = false
		}
	}

	@IBAction private func resumeInterruptedSession(_ sender: UIButton) {
		sessionQueue.async {
			/*
				The session might fail to start running. A failure to start the session running will be communicated via
				a session runtime error notification. To avoid repeatedly failing to start the session
				running, we only try to restart the session running in the session runtime error handler
				if we aren't trying to resume the session running.
			*/
			self.session.startRunning()
			self.isSessionRunning = self.session.isRunning
			if !self.session.isRunning {
				DispatchQueue.main.async {
					let message = NSLocalizedString("Unable to resume", comment: "Alert message when unable to resume the session running")
					let alertController = UIAlertController(title: "AVDepthCamera", message: message, preferredStyle: .alert)
					let cancelAction = UIAlertAction(title:NSLocalizedString("OK", comment: "Alert OK button"), style: .cancel, handler: nil)
					alertController.addAction(cancelAction)
					self.present(alertController, animated: true, completion: nil)
				}
			} else {
				DispatchQueue.main.async {
					self.resumeButton.isHidden = true
				}
			}
		}
	}
    
    @objc func startRecord() {
        self.recordButton.isSelected = !self.recordButton.isSelected
        if self.recordButton.isSelected {
            self.recordingEnabled = true
            self.recordButton.setTitle("End", for: UIControlState.normal)
        }else{
            self.recordingEnabled = false
            self.recordButton.setTitle("Start", for: UIControlState.normal)
        }
    }
    
	@IBAction private func capturePhoto(_ photoButton: UIButton) {
		let depthEnabled = true
		sessionQueue.async {
			let photoSettings = AVCapturePhotoSettings(format: [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)])
			if depthEnabled && self.photoOutput.isDepthDataDeliverySupported {
				photoSettings.isDepthDataDeliveryEnabled = true
				photoSettings.embedsDepthDataInPhoto = false
			}
            
            self.photoOutput.capturePhoto(with: photoSettings, delegate: self)
		}
	}

	// MARK: - Video Data Output Delegate

	func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
		processVideo(sampleBuffer: sampleBuffer)
	}

	func processVideo(sampleBuffer: CMSampleBuffer) {
		if !renderingEnabled {
			return
		}

		guard let videoPixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
			let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
			return
		}
        
        /*let startTime = Double(self.currentTime)
        let elapsed = startTime!-self.totalTimeIntervalForRGB
        if elapsed >= 1700 {//5 frame per seconds
            self.totalTimeIntervalForRGB = Double(self.currentTime)!
            if self.recordingEnabled && self.recordingRGBPerFrameFinished==false {
                DispatchQueue.global().async {
                    autoreleasepool {
                        self.recordingRGBPerFrameFinished = true
                        let image = self.imageFromPixelBuffer(pixelBuffer: videoPixelBuffer).fixedOrientation().rotate(radians: Float(90.0*Double.pi/180.0))
                        let rgbFolderPath = self.getFolderPath(imagePath: "RGBImages")
                        let rgbFolderURL = NSURL.fileURL(withPath: rgbFolderPath)
                        var fileName = self.currentTime
                        fileName.append(".jpeg")
                        let imageURL = rgbFolderURL.appendingPathComponent(fileName)
                        self.saveFile(fileUrl: imageURL, image: image!, fileType: kUTTypeJPEG)
                        
                        //let imageData = UIImageJPEGRepresentation(image!, 1.0)
                        //try! imageData?.write(to: imageURL)
                    }
                }
            }
        }*/
        
		var finalVideoPixelBuffer = videoPixelBuffer
		if depthVisualizationEnabled {
			if !videoDepthMixer.isPrepared {
				videoDepthMixer.prepare(with: formatDescription, outputRetainedBufferCountHint: 3)
			}

			if let depthBuffer = currentDepthPixelBuffer {

				// Mix the video buffer with the last depth data we received
				guard let mixedBuffer = videoDepthMixer.mix(videoPixelBuffer: finalVideoPixelBuffer, depthPixelBuffer: depthBuffer) else {
					print("Unable to combine video and depth")
					return
				}

				finalVideoPixelBuffer = mixedBuffer
			}
		}
        
		previewView.pixelBuffer = finalVideoPixelBuffer
	}
    
    //Covert PixelBuffer To UIImage
    func imageFromPixelBuffer(pixelBuffer : CVPixelBuffer) -> UIImage
    {
        var cgImage: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixelBuffer, nil, &cgImage)
        return UIImage (cgImage: cgImage!);
    }
    

	// MARK: - Depth Data Output Delegate

	func depthDataOutput(_ depthDataOutput: AVCaptureDepthDataOutput, didOutput depthData: AVDepthData, timestamp: CMTime, connection: AVCaptureConnection) {
		processDepth(depthData: depthData)
	}

	func processDepth(depthData: AVDepthData) {
		if !renderingEnabled {
			return
		}

		if !depthVisualizationEnabled {
			return
		}

		if !videoDepthConverter.isPrepared {
			/*
			outputRetainedBufferCountHint is the number of pixel buffers we expect to hold on to from the renderer. This value informs the renderer
			how to size its buffer pool and how many pixel buffers to preallocate. Allow 2 frames of latency to cover the dispatch_async call.
			*/
			var depthFormatDescription: CMFormatDescription?
			CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, depthData.depthDataMap, &depthFormatDescription)
			videoDepthConverter.prepare(with: depthFormatDescription!, outputRetainedBufferCountHint: 2)
		}

		guard let depthPixelBuffer = videoDepthConverter.render(pixelBuffer: depthData.depthDataMap) else {
			print("Unable to process depth")
			return
		}
        
        let startTime = Double(self.currentTime)
        let elapsed = startTime!-self.totalTimeIntervalForDepth
        if elapsed >= 1700 {//5 frame per seconds
            self.totalTimeIntervalForDepth = Double(self.currentTime)!
            if self.recordingEnabled && self.recordingDepthPerFrameFinished==false {
                DispatchQueue.global().async {
                    autoreleasepool {
                        self.recordingDepthPerFrameFinished = true
                        let image = self.imageFromPixelBuffer(pixelBuffer: depthPixelBuffer).fixedOrientation().rotate(radians: Float(90.0*Double.pi/180.0))
                        let rgbFolderPath = self.getFolderPath(imagePath: "DepthImages")
                        let rgbFolderURL = NSURL.fileURL(withPath: rgbFolderPath)
                        var fileName = self.currentTime
                        fileName.append(".png")
                        let imageURL = rgbFolderURL.appendingPathComponent(fileName)
                        self.saveFile(fileUrl: imageURL, image: image!, fileType: kUTTypePNG)
                        
                        //let imageData = UIImagePNGRepresentation(image!)
                        //try! imageData?.write(to: imageURL)
                    }
                }
            }
        }

		currentDepthPixelBuffer = depthPixelBuffer
	}

	// MARK: - Video + Depth Output Synchronizer Delegate

	func dataOutputSynchronizer(_ synchronizer: AVCaptureDataOutputSynchronizer, didOutput synchronizedDataCollection: AVCaptureSynchronizedDataCollection) {

		if let syncedDepthData: AVCaptureSynchronizedDepthData = synchronizedDataCollection.synchronizedData(for: depthDataOutput) as? AVCaptureSynchronizedDepthData {
			if !syncedDepthData.depthDataWasDropped {
				let depthData = syncedDepthData.depthData
				processDepth(depthData: depthData)
			}
		}

		if let syncedVideoData: AVCaptureSynchronizedSampleBufferData = synchronizedDataCollection.synchronizedData(for: videoDataOutput) as? AVCaptureSynchronizedSampleBufferData {
			if !syncedVideoData.sampleBufferWasDropped {
				let videoSampleBuffer = syncedVideoData.sampleBuffer
				processVideo(sampleBuffer: videoSampleBuffer)
			}
		}
	}

	// MARK: - Photo Output Delegate

	func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {

        guard let photoPixelBuffer = photo.pixelBuffer else {
			print("Error occurred while capturing photo: Missing pixel buffer (\(String(describing: error)))")
			return
		}

		var photoFormatDescription: CMFormatDescription?
		CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, photoPixelBuffer, &photoFormatDescription)

		processingQueue.async {
			var finalPixelBuffer = photoPixelBuffer
			if let depthData = photo.depthData {
				let depthPixelBuffer = depthData.depthDataMap

				if !self.photoDepthConverter.isPrepared {
					var depthFormatDescription: CMFormatDescription?
					CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, depthPixelBuffer, &depthFormatDescription)

					/*
					outputRetainedBufferCountHint is the number of pixel buffers we expect to hold on to from the renderer. This value informs the renderer
					how to size its buffer pool and how many pixel buffers to preallocate. Allow 3 frames of latency to cover the dispatch_async call.
					*/
					self.photoDepthConverter.prepare(with: depthFormatDescription!, outputRetainedBufferCountHint: 3)
				}

				guard let convertedDepthPixelBuffer = self.photoDepthConverter.render(pixelBuffer: depthPixelBuffer) else {
					print("Unable to convert depth pixel buffer")
					return
				}

				if !self.photoDepthMixer.isPrepared {
					self.photoDepthMixer.prepare(with: photoFormatDescription!, outputRetainedBufferCountHint: 2)
				}

				// Combine image and depth map
				guard let mixedPixelBuffer = self.photoDepthMixer.mix(videoPixelBuffer: finalPixelBuffer, depthPixelBuffer: convertedDepthPixelBuffer) else {
					print("Unable to mix depth and photo buffers")
					return
				}

				finalPixelBuffer = mixedPixelBuffer
			}

			let metadataAttachments: CFDictionary = photo.metadata as CFDictionary
			guard let pngData = CameraViewController.pngData(withPixelBuffer: finalPixelBuffer, attachments: metadataAttachments) else {
				print("Unable to create PNG photo")
				return
			}

			// Save JPEG to photo library
            PHPhotoLibrary.requestAuthorization { status in
                if status == .authorized {
                    PHPhotoLibrary.shared().performChanges({
                        let creationRequest = PHAssetCreationRequest.forAsset()
                        creationRequest.addResource(with: .photo, data: pngData, options: nil)
                    }, completionHandler: { _, error in
                        if let error = error {
                            print("Error occurred while saving photo to photo library: \(error)")
                        }
                    })
                }
            }
		}
	}

	// MARK: - Utilities

    private func saveFile (fileUrl:URL, image:UIImage, fileType:CFString) {
        let url = fileUrl as CFURL
        let destination = CGImageDestinationCreateWithURL(url, fileType, 1, nil);
        if nil==destination {
            return
        }
        
        CGImageDestinationAddImage(destination!, image.cgImage!, nil)
        CGImageDestinationFinalize(destination!)
    
        if fileType==kUTTypeJPEG {
            self.recordingRGBPerFrameFinished = false
        }else{
            self.recordingDepthPerFrameFinished = false
        }
    }

	private class func pngData(withPixelBuffer pixelBuffer: CVPixelBuffer, attachments: CFDictionary?) -> Data? {
		let ciContext = CIContext()
		let renderedCIImage = CIImage(cvImageBuffer: pixelBuffer)
		guard let renderedCGImage = ciContext.createCGImage(renderedCIImage, from: renderedCIImage.extent) else {
			print("Failed to create CGImage")
			return nil
		}

		guard let data = CFDataCreateMutable(kCFAllocatorDefault, 0) else {
			print("Create CFData error!")
			return nil
		}

		guard let cgImageDestination = CGImageDestinationCreateWithData(data, kUTTypePNG, 1, nil) else {
			print("Create CGImageDestination error!")
			return nil
		}

		CGImageDestinationAddImage(cgImageDestination, renderedCGImage, attachments)
		if CGImageDestinationFinalize(cgImageDestination) {
			return data as Data
		}
		print("Finalizing CGImageDestination error!")
		return nil
	}
}

extension UIInterfaceOrientation {
	var videoOrientation: AVCaptureVideoOrientation? {
		switch self {
			case .portrait: return .portrait
			case .portraitUpsideDown: return .portraitUpsideDown
			case .landscapeLeft: return .landscapeLeft
			case .landscapeRight: return .landscapeRight
			default: return nil
		}
	}
}

extension PreviewMetalView.Rotation {
	init?(with interfaceOrientation: UIInterfaceOrientation, videoOrientation: AVCaptureVideoOrientation, cameraPosition: AVCaptureDevice.Position) {
		/*
			Calculate the rotation between the videoOrientation and the interfaceOrientation.
			The direction of the rotation depends upon the camera position.
		*/
		switch videoOrientation {
			case .portrait:
				switch interfaceOrientation {
					case .landscapeRight:
						if cameraPosition == .front {
							self = .rotate90Degrees
						} else {
							self = .rotate270Degrees
					}

				case .landscapeLeft:
					if cameraPosition == .front {
						self = .rotate270Degrees
					} else {
						self = .rotate90Degrees
					}

				case .portrait:
					self = .rotate0Degrees

				case .portraitUpsideDown:
					self = .rotate180Degrees

				default: return nil
			}
		case .portraitUpsideDown:
			switch interfaceOrientation {
			case .landscapeRight:
				if cameraPosition == .front {
					self = .rotate270Degrees
				} else {
					self = .rotate90Degrees
				}

			case .landscapeLeft:
				if cameraPosition == .front {
					self = .rotate90Degrees
				} else {
					self = .rotate270Degrees
				}

			case .portrait:
				self = .rotate180Degrees

			case .portraitUpsideDown:
				self = .rotate0Degrees

			default: return nil
			}

		case .landscapeRight:
			switch interfaceOrientation {
			case .landscapeRight:
				self = .rotate0Degrees

			case .landscapeLeft:
				self = .rotate180Degrees

			case .portrait:
				if cameraPosition == .front {
					self = .rotate270Degrees
				} else {
					self = .rotate90Degrees
				}

			case .portraitUpsideDown:
				if cameraPosition == .front {
					self = .rotate90Degrees
				} else {
					self = .rotate270Degrees
				}

			default: return nil
			}

		case .landscapeLeft:
			switch interfaceOrientation {
			case .landscapeLeft:
				self = .rotate0Degrees

			case .landscapeRight:
				self = .rotate180Degrees

			case .portrait:
				if cameraPosition == .front {
					self = .rotate90Degrees
				} else {
					self = .rotate270Degrees
				}

			case .portraitUpsideDown:
				if cameraPosition == .front {
					self = .rotate270Degrees
				} else {
					self = .rotate90Degrees
				}

			default: return nil
			}
		}
	}
}

extension UIImage {
    func rotate(radians: Float) -> UIImage? {
        var newSize = CGRect(origin: CGPoint.zero, size: self.size).applying(CGAffineTransform(rotationAngle: CGFloat(radians))).size
        //Trim off the extremely small float value to prevent core graphics from rounding it up
        newSize.width = floor(newSize.width)
        newSize.height = floor(newSize.height)
        
        UIGraphicsBeginImageContext(newSize);
        let context = UIGraphicsGetCurrentContext()!
        
        //Move origin to middle
        context.translateBy(x: newSize.width/2, y: newSize.height/2)
        //Rotate around middle
        context.rotate(by: CGFloat(radians))
        
        self.draw(in: CGRect(x: -self.size.width/2, y: -self.size.height/2, width: self.size.width, height: self.size.height))
        
        let newImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        
        return newImage
    }
    
    public func imageRotatedByDegrees(degrees: CGFloat) -> UIImage {
        //Calculate the size of the rotated view's containing box for our drawing space
        let rotatedViewBox: UIView = UIView(frame: CGRect(x: 0, y: 0, width: self.size.width, height: self.size.height))
        let t: CGAffineTransform = CGAffineTransform(rotationAngle: degrees * CGFloat.pi / 180)
        rotatedViewBox.transform = t
        let rotatedSize: CGSize = rotatedViewBox.frame.size
        //Create the bitmap context
        UIGraphicsBeginImageContext(rotatedSize)
        let bitmap: CGContext = UIGraphicsGetCurrentContext()!
        //Move the origin to the middle of the image so we will rotate and scale around the center.
        bitmap.translateBy(x: rotatedSize.width / 2, y: rotatedSize.height / 2)
        //Rotate the image context
        bitmap.rotate(by: (degrees * CGFloat.pi / 180))
        //Now, draw the rotated/scaled image into the context
        bitmap.scaleBy(x: 1.0, y: -1.0)
        bitmap.draw(self.cgImage!, in: CGRect(x: -self.size.width / 2, y: -self.size.height / 2, width: self.size.width, height: self.size.height))
        let newImage: UIImage = UIGraphicsGetImageFromCurrentImageContext()!
        UIGraphicsEndImageContext()
        return newImage
    }
    
    public func fixedOrientation() -> UIImage {
        if imageOrientation == UIImageOrientation.up {
            return self
        }
        
        var transform: CGAffineTransform = CGAffineTransform.identity
        
        switch imageOrientation {
        case UIImageOrientation.down, UIImageOrientation.downMirrored:
            transform = transform.translatedBy(x: size.width, y: size.height)
            transform = transform.rotated(by: CGFloat.pi)
            break
        case UIImageOrientation.left, UIImageOrientation.leftMirrored:
            transform = transform.translatedBy(x: size.width, y: 0)
            transform = transform.rotated(by: CGFloat.pi/2)
            break
        case UIImageOrientation.right, UIImageOrientation.rightMirrored:
            transform = transform.translatedBy(x: 0, y: size.height)
            transform = transform.rotated(by: -CGFloat.pi/2)
            break
        case UIImageOrientation.up, UIImageOrientation.upMirrored:
            break
        }
        
        switch imageOrientation {
        case UIImageOrientation.upMirrored, UIImageOrientation.downMirrored:
            transform.translatedBy(x: size.width, y: 0)
            transform.scaledBy(x: -1, y: 1)
            break
        case UIImageOrientation.leftMirrored, UIImageOrientation.rightMirrored:
            transform.translatedBy(x: size.height, y: 0)
            transform.scaledBy(x: -1, y: 1)
        case UIImageOrientation.up, UIImageOrientation.down, UIImageOrientation.left, UIImageOrientation.right:
            break
        }
        
        let ctx: CGContext = CGContext(data: nil,
                                       width: Int(size.width),
                                       height: Int(size.height),
                                       bitsPerComponent: self.cgImage!.bitsPerComponent,
                                       bytesPerRow: 0,
                                       space: self.cgImage!.colorSpace!,
                                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        
        ctx.concatenate(transform)
        
        switch imageOrientation {
        case UIImageOrientation.left, UIImageOrientation.leftMirrored, UIImageOrientation.right, UIImageOrientation.rightMirrored:
            ctx.draw(self.cgImage!, in: CGRect(x: 0, y: 0, width: size.height, height: size.width))
        default:
            ctx.draw(self.cgImage!, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
            break
        }
        
        let cgImage: CGImage = ctx.makeImage()!
        
        return UIImage(cgImage: cgImage)
    }
}
