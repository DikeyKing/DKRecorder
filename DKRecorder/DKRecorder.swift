//
//  DKRecorder.swift
//  DKRecordDemo
//
//  Created by Dikey on 2020/1/18.
//  Copyright © 2020 Dikey. All rights reserved.
//

import Foundation
import AVFoundation
import UIKit
import QuartzCore
import AssetsLibrary

protocol RecorderProtocol {
    func writeBackgroundFrameInContext(contextRef:CGContext)
}

class Recorder: NSObject {
    static let shared = Recorder.init()
    
    /// if is recording
    private(set) var recording:Bool = false
    
    /// if saveURL is nil, video will be saved into camera roll, do not change url when recording
    var videoURL:URL?
    
    /// if nil , UIWindow is insted
    var viewToCapture:UIView?
    
    /// if YES , write to PhotoLibrary after finishing recording
    var writeToPhotoLibrary:Bool = false
    
    /// show  eclpsed time
    var runBenchmark:Bool = false

    fileprivate var totalFrameTimeDuringCapture:CGFloat = 0
    fileprivate var numberOfFramesCaptured = 0

    // Video Properties
    fileprivate var videoWriter: AVAssetWriter?
    fileprivate var videoWriterInput: AVAssetWriterInput?
    fileprivate var avAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    fileprivate var displayLink: CADisplayLink?
    fileprivate var outputBufferPoolAuxAttributes: [AnyHashable : Any]?
    fileprivate var captureSession: AVCaptureSession?

    //Audio Properties
    fileprivate var audioCaptureInput: AVCaptureDeviceInput?
    fileprivate var audioInput: AVAssetWriterInput?
    fileprivate var audioCaptureOutput: AVCaptureAudioDataOutput?
    fileprivate var audioSettings: [AnyHashable : Any]?
    fileprivate var firstAudioTimeStamp: CMTime!
    fileprivate var startedAt: Date?
    fileprivate var firstTimeStamp: CFTimeInterval = 0
    
    fileprivate var _audio_capture_queue: DispatchQueue!
    fileprivate var _render_queue: DispatchQueue!
    fileprivate var _append_pixelBuffer_queue: DispatchQueue!
    fileprivate var _frameRenderingSemaphore: DispatchSemaphore!
    fileprivate var _pixelAppendSemaphore: DispatchSemaphore!

    fileprivate var viewSize: CGSize?
    fileprivate var scale: CGFloat!

    fileprivate var _rgbColorSpace: CGColorSpace? = nil
    fileprivate var _outputBufferPool: CVPixelBufferPool? = nil
    
    override init() {
        super.init()
        
        // init
        self.viewSize = UIApplication.shared.delegate?.window??.bounds.size
        scale = UIScreen.main.scale

        _append_pixelBuffer_queue = DispatchQueue(label: "ASScreenRecorder.append_queue")
        _render_queue = DispatchQueue(label: "ASScreenRecorder.render_queue")
        _render_queue.setTarget(queue: DispatchQueue.global(qos: .default))
        _frameRenderingSemaphore = DispatchSemaphore(value: 1) //单线程
        _pixelAppendSemaphore = DispatchSemaphore(value: 1)
        
        setUpAudioCapture()
    }
    
    func setUpAudioCapture(){
        let device = AVCaptureDevice.default(for: .audio)
        if device != nil && device?.isConnected ?? false {
            print("Connected Device: \(device?.localizedName ?? "")")
        } else {
            print("AVCaptureDevice Failed")
            return
        }
        
        // add device inputs
        do {
            if let device = device {
                audioCaptureInput = try AVCaptureDeviceInput(device: device)
            }
        } catch {
            print("AVCaptureDeviceInput Failed")
            return
        }

        // add output for audio
        audioCaptureOutput = AVCaptureAudioDataOutput()
        guard audioCaptureOutput != nil else {
            print("AVCaptureMovieFileOutput Failed")
            return
        }

        _audio_capture_queue = DispatchQueue(label: "AudioCaptureQueue")
        audioCaptureOutput!.setSampleBufferDelegate(self, queue: _audio_capture_queue)

        captureSession = AVCaptureSession()
        guard captureSession != nil else {
            print("AVCaptureSession Failed")
            return
        }

        captureSession!.sessionPreset = .medium
        if captureSession!.canAddInput(audioCaptureInput!) {
            captureSession!.addInput(audioCaptureInput!)
        } else {
            print("Failed to add input device to capture session")
            return
        }
        
        if captureSession!.canAddOutput(audioCaptureOutput!) {
            captureSession!.addOutput(audioCaptureOutput!)
        } else {
            print("Failed to add output device to capture session")
            return
        }

        audioSettings = audioCaptureOutput!.recommendedAudioSettingsForAssetWriter(writingTo: .mov)
    }
    
    public func startRecording()->Bool {
        if self.recording {
            self.captureSession?.startRunning()
            self.setUpWriter()
            recording = (self.videoWriter?.status == .writing)
            self.displayLink?.add(to: RunLoop.main , forMode: .common)
        }
        return self.recording
    }

    
    public func stopRecording(resultCallback:@escaping(_ result:URL?)->()?){
        
    }
    
    func setUpWriter(){
        self._rgbColorSpace = CGColorSpaceCreateDeviceRGB()
        
        // create out CVPixelBufferPool
        _outputBufferPool = nil
        let outputBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String:Int(1),
            kCVPixelBufferWidthKey as String: Int(self.viewSize!.width * self.scale),
            kCVPixelBufferHeightKey as String: Int(self.viewSize!.height * self.scale),
            kCVPixelBufferBytesPerRowAlignmentKey as String: Int(self.viewSize!.width * self.viewSize!.height * self.scale)
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, outputBufferAttributes as NSDictionary?, &_outputBufferPool);

        do {
//            self.videoWriter = try AVAssetWriter.init(outputURL: self.videoURL?, fileType:. )
            
        } catch {

            return
        }
    }
    
    // MARK: - Private
    static private func allocateOutputBufferPool(with formatDescription: CMFormatDescription,
                                                 outputRetainedBufferCountHint: Int) -> CVPixelBufferPool? {
        let inputDimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
        let outputBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(inputDimensions.width),
            kCVPixelBufferHeightKey as String: Int(inputDimensions.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]

        let poolAttributes = [kCVPixelBufferPoolMinimumBufferCountKey as String: outputRetainedBufferCountHint]
        var cvPixelBufferPool: CVPixelBufferPool?
        // Create a pixel buffer pool with the same pixel attributes as the input format description
        CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttributes as NSDictionary?, outputBufferAttributes as NSDictionary?, &cvPixelBufferPool)
        guard let pixelBufferPool = cvPixelBufferPool else {
            assertionFailure("Allocation failure: Could not create pixel buffer pool")
            return nil
        }
        return pixelBufferPool
    }
    
}

extension Recorder:AVCaptureAudioDataOutputSampleBufferDelegate{
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection){

    }
}
