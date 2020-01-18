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

    fileprivate var viewSize: CGSize? = UIApplication.shared.delegate?.window??.bounds.size
    fileprivate var scale: CGFloat!

    fileprivate var _rgbColorSpace: CGColorSpace? = nil
    fileprivate var _outputBufferPool: CVPixelBufferPool? = nil
    
    fileprivate var tempFileURL:URL {
        get{
            let outputPath = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("tmp/screenCapture.mov").absoluteString
            removeTempFilePath(outputPath)
            return URL(fileURLWithPath: outputPath)
        }
    }
    
    override init() {
        super.init()
        
        // init
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
        if self.recording{
            self.captureSession?.stopRunning()
            self.recording = false
            self.displayLink?.remove(from: RunLoop.main, forMode: .common)
            
        }
    }
    
    // MARK: - Private
    
    fileprivate func setUpWriter(){
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

        let fileURL:URL = self.videoURL ?? self.tempFileURL
        guard let videoWriter = try? AVAssetWriter.init(outputURL: fileURL, fileType: .mov) else {
             fatalError("AVAssetWriter error")
         }
        self.videoWriter = videoWriter
        
        let pixelNumber = self.viewSize!.width * self.viewSize!.height * scale * self.scale
        let videoCompression = [
            AVVideoAverageBitRateKey: NSNumber(value: Double(pixelNumber) * 11.4)
        ]
        let outputSettings = [AVVideoCodecKey : AVVideoCodecType.h264,
                              AVVideoWidthKey : NSNumber(value: Float(self.viewSize!.width * self.scale)),
                              AVVideoHeightKey : NSNumber(value: Float(self.viewSize!.height * self.scale)),
                              AVVideoCompressionPropertiesKey : videoCompression] as [String : Any]
        guard videoWriter.canApply(outputSettings: outputSettings, forMediaType: AVMediaType.video) else {
            fatalError("Negative : Can't apply the Output settings...")
        }

        let videoWriterInput = AVAssetWriterInput(mediaType: AVMediaType.video, outputSettings: outputSettings)
        videoWriterInput.expectsMediaDataInRealTime = true
        videoWriterInput.transform = self.videoTransformForDeviceOrientation()
        self.videoWriter?.add(videoWriterInput)
        self.videoWriterInput = videoWriterInput

        let pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoWriterInput,
                                                                      sourcePixelBufferAttributes: nil)
        self.avAdaptor = pixelBufferAdaptor
        self.videoWriter?.startWriting()
        self.videoWriter?.startSession(atSourceTime: self.firstAudioTimeStamp)
    }
    
    fileprivate func videoTransformForDeviceOrientation() -> CGAffineTransform {
        var videoTransform: CGAffineTransform
        switch UIDevice.current.orientation {
            case .landscapeLeft:
                videoTransform = CGAffineTransform(rotationAngle: CGFloat(-Double.pi/2))
            case .landscapeRight:
                videoTransform = CGAffineTransform(rotationAngle: CGFloat(Double.pi/2))
            case .portraitUpsideDown:
                videoTransform = CGAffineTransform(rotationAngle: .pi)
            default:
                videoTransform = .identity
        }
        return videoTransform
    }

    fileprivate func completeRecordingSession(completionCallback:@escaping(_ result:URL?)->()?){
        self._render_queue.async(execute: {
            self._append_pixelBuffer_queue.sync(execute: {
                self._audio_capture_queue.sync(execute: {
                    self.audioInput?.markAsFinished()
                    self.videoWriterInput?.markAsFinished()
                    self.videoWriter?.finishWriting(completionHandler: {
                        self.saveToPhotoLibrary()
                        let completion:((_ url: URL?) -> Void) = { url in
                            self.cleanup()
                            DispatchQueue.main.async(execute: {
                                completionCallback(url)
                            })
                        }
                        let videoURL = self.videoURL ?? self.videoWriter?.outputURL
                        completion(videoURL)
                    })
                })
            })
        })
    }

    fileprivate func cleanup() {
        avAdaptor = nil
        videoWriterInput = nil
        videoWriter = nil
        firstTimeStamp = 0
        startedAt = nil
        firstAudioTimeStamp = CMTime.zero
        outputBufferPoolAuxAttributes = nil
    }

    fileprivate func saveToPhotoLibrary(){
        guard let outputURL = self.videoWriter?.outputURL else {
            print("Error saveToPhotoLibrary: outputURL is nil")
            return
        }
        if self.writeToPhotoLibrary == true{
            ALAssetsLibrary().writeVideoAtPath(toSavedPhotosAlbum: outputURL,
                                               completionBlock: {assetURL, error in
                if error != nil {
                    print("Error copying video to camera roll:\(error?.localizedDescription ?? "")")
                } else {
                    // remove ?
                }
            })
        }
    }
    
    fileprivate func removeTempFilePath(_ filePath: String?) {
        guard let filePath = filePath else {
            return
        }
        if FileManager.default.fileExists(atPath: filePath) {
            do {
                try FileManager.default.removeItem(atPath: filePath)
            } catch {
                print("Error removing ")
            }
        }
    }
}

extension Recorder:AVCaptureAudioDataOutputSampleBufferDelegate{
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection){

    }
}
