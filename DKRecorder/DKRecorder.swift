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
import Photos

let INITIALFRAMESTOIGNOREFORBENCHMARK = 5

protocol RecorderProtocol:AnyObject{
    func writeBackgroundFrameInContext(contextRef:CGContext)
}

class Recorder: NSObject {
    //    static let shared = Recorder.init()
    
    weak var delegate:RecorderProtocol?
    
    /// if is recording
    private(set) public var recording:Bool = false

    /// if saveURL is nil, video will be saved into camera roll, do not change url when recording
    var videoURL:URL?
    
    /// if nil , UIWindow is insted
    var viewToCapture:UIView?
    
    /// if YES , write to PhotoLibrary after finishing recording
    var writeToPhotoLibrary:Bool = false
    
    /// show  eclpsed time
    var runBenchmark:Bool = false
    
    /// call before startRecording
    var recordAudio:Bool = true
    
    fileprivate var totalFrameTimeDuringCapture:Double = 0
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
    fileprivate var audioSettings: [String : Any]?
    fileprivate var firstAudioTimeStamp: CMTime!
    fileprivate var startedAt: Date?
    fileprivate var firstTimeStamp: CFTimeInterval = 0

    fileprivate var _audio_capture_queue: DispatchQueue!
    fileprivate var _render_queue: DispatchQueue!
    fileprivate var _append_pixelBuffer_queue: DispatchQueue!
    fileprivate var _frameRenderingSemaphore: DispatchSemaphore!
    fileprivate var _pixelAppendSemaphore: DispatchSemaphore!
    
    fileprivate var waitToStart: Bool = false
    fileprivate var audioReady: Bool = false
    
    fileprivate var viewSize: CGSize = UIScreen.main.bounds.size
//    fileprivate var viewSize: CGSize = CGSize.init(width: 320, height: 568)
    fileprivate var scale: CGFloat = UIScreen.main.scale
    fileprivate var outputBufferPool: CVPixelBufferPool? = nil
    fileprivate var rgbColorSpace: CGColorSpace? = nil

    override init() {
        super.init()
        _append_pixelBuffer_queue = DispatchQueue.init(label: "ScreenRecorder.append_queue")
        _render_queue = DispatchQueue.init(label: "ScreenRecorder.render_queue")
        _frameRenderingSemaphore = DispatchSemaphore(value: 1)
        _pixelAppendSemaphore = DispatchSemaphore(value: 1)
    }
    
    @discardableResult public func startRecording()-> Bool {
        if self.recording == false {
            self.setUpAudioCapture()
            self.captureSession?.startRunning()
            self.setUpWriter()
                        
            recording = (self.videoWriter?.status == .writing)
            self.displayLink = CADisplayLink(target: self, selector: #selector(writeVideoFrame))
            self.displayLink?.add(to: RunLoop.main , forMode: .common)
        }
        return self.recording
    }
    
    public func stopRecording(resultCallback:@escaping(URL?)->Void){
        if self.recording{
            self.waitToStart = false
            self.audioReady = false
            self.captureSession?.stopRunning()
            self.recording = false
            self.displayLink?.remove(from: RunLoop.main, forMode: .common)
            self.completeRecordingSession(completionCallback: resultCallback)
        }
    }
    
    fileprivate func createVideoWriterInput(videoSetting:[String : Any])->AVAssetWriterInput{
        let videoWriterInput = AVAssetWriterInput(mediaType: AVMediaType.video, outputSettings: videoSetting)
        videoWriterInput.expectsMediaDataInRealTime = true
        videoWriterInput.transform = self.videoTransformForDeviceOrientation()
        return videoWriterInput
    }
    
    fileprivate func createVideoWriter(settings:[String : Any])->AVAssetWriter{
        let fileURL:URL = self.videoURL ?? self.tempFileURL
        guard let videoWriter = try? AVAssetWriter.init(outputURL: fileURL, fileType: .mov) else {
            fatalError("AVAssetWriter error")
        }
        guard videoWriter.canApply(outputSettings: settings, forMediaType: AVMediaType.video) else {
            fatalError("Negative : Can't apply the Output settings...")
        }
        return videoWriter
    }

    fileprivate func setUpWriter(){
        
        self.rgbColorSpace = CGColorSpaceCreateDeviceRGB()
        
        // 1. pixelBuffer
        outputBufferPool = nil
        let outputBufferAttributes = self.outputBufferAttributes()
        CVPixelBufferPoolCreate(nil, nil, outputBufferAttributes as CFDictionary, &outputBufferPool);
        
        // 2. videoWriterInput
        let videoSettings = self.videoSettings()
        
        // 3. videoWriter
        self.videoWriterInput = self.createVideoWriterInput(videoSetting: videoSettings)
        self.videoWriter = self.createVideoWriter(settings: videoSettings)
        self.videoWriter?.add(videoWriterInput!)
        guard videoWriter!.canApply(outputSettings: videoSettings, forMediaType: AVMediaType.video) else {
            fatalError("Negative : Can't apply the Output settings...")
        }
        guard let audioInput = self.audioInput else {
            print("error creating audioInput")
            return
        }
        guard videoWriter!.canAdd(audioInput) else {
            fatalError("add audioInput")
        }
        self.videoWriter?.add(audioInput)
        
        // 4. avAdaptor
        self.avAdaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoWriterInput!,
                                                              sourcePixelBufferAttributes: nil)
        if self.videoWriter!.startWriting() == false {
            print("startWriting failled")
            return
        }
        if let status = self.videoWriter?.status{
            switch status {
            case .writing:
                if self.audioReady == true {
                    self.videoWriter?.startSession(atSourceTime: self.firstAudioTimeStamp)
                }else{
                    self.waitToStart = true
                }
                break
            default:
                print("error")
                break
            }
        }
    }
    
    fileprivate func outputBufferAttributes()->[String: Any]{
        let outputBufferAttributes:[String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String:Int(1),
            kCVPixelBufferWidthKey as String: NSNumber(value: Int(self.viewSize.width * self.scale))  ,
            kCVPixelBufferHeightKey as String: NSNumber(value:  Int(self.viewSize.height * self.scale)) ,
            kCVPixelBufferBytesPerRowAlignmentKey as String: Int(self.viewSize.width * self.scale * 4)
        ]
        return outputBufferAttributes
    }
    
    fileprivate func videoSettings()->[String : Any]{
        let pixelNumber = self.viewSize.width * self.viewSize.height * scale
        let videoCompression = [
            AVVideoAverageBitRateKey: NSNumber(value: Int(Double(pixelNumber) * 11.4))
        ]
        let videoSettings = [AVVideoCodecKey : AVVideoCodecType.h264,
                              AVVideoWidthKey : NSNumber(value: Int(self.viewSize.width * self.scale)),
                              AVVideoHeightKey : NSNumber(value: Int(self.viewSize.height * self.scale)),
                              AVVideoCompressionPropertiesKey : videoCompression] as [String : Any]
        return videoSettings
    }
    
    fileprivate func videoTransformForDeviceOrientation() -> CGAffineTransform {
        var videoTransform: CGAffineTransform
        switch UIDevice.current.orientation {
        case .landscapeLeft:
            videoTransform = CGAffineTransform(rotationAngle: CGFloat(-Double.pi/2))
            break
            
        case .landscapeRight:
            videoTransform = CGAffineTransform(rotationAngle: CGFloat(Double.pi/2))
            break
            
        case .portraitUpsideDown:
            videoTransform = CGAffineTransform(rotationAngle: .pi)
            break

        default:
            videoTransform = .identity
        }
        return videoTransform
    }
    
    fileprivate func completeRecordingSession(completionCallback:@escaping(_ result:URL?)->()?){
        self._render_queue.async(execute: {
            self._append_pixelBuffer_queue.sync(execute: {
                self.audioInput?.markAsFinished()
                self.videoWriterInput?.markAsFinished()
                self.videoWriter?.finishWriting(completionHandler: {
                    let completion:((_ url: URL?) -> Void) = { url in
                        self.cleanup()
                        DispatchQueue.main.async(execute: {
                            completionCallback(url)
                        })
                    }
                    if let videoURL = self.videoURL ?? self.videoWriter?.outputURL{
                        if self.writeToPhotoLibrary == true{
                            PHPhotoLibrary.shared().performChanges({
                                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: videoURL)
                            }) { saved, error in
                                if error != nil {
                                    print("Error copying video to camera roll:\(error?.localizedDescription ?? "")")
                                }
                                completion(videoURL)
                            }
                        }else{
                            completion(videoURL)
                        }
                    }
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
        
        displayLink = nil
        outputBufferPoolAuxAttributes = nil
        print("clean up")

        self.audioReady = false
        self.waitToStart = false
    }
    
    @objc fileprivate func writeVideoFrame(){
        // http://stackoverflow.com/a/5956119
        if self.waitToStart {
            return
        }
        if self._frameRenderingSemaphore.wait(timeout: DispatchTime.now()) != .success  {
            return //ensure only one frame to be writed at same time
        }
        guard let displayLink = self.displayLink else {
            print("displayLink is nil")
            return
        }
        self._render_queue.async {
            if self.videoWriterInput?.isReadyForMoreMediaData == false{
                return
            }
            if self.firstTimeStamp == 0{
                self.firstTimeStamp = displayLink.timestamp
            }
            
            let elapsed: CFTimeInterval = displayLink.timestamp - self.firstTimeStamp
            let time = CMTimeAdd(self.firstAudioTimeStamp, CMTimeMakeWithSeconds(Float64(elapsed), preferredTimescale: 1000))
            
            var pixelBuffer: CVPixelBuffer? = nil
            guard let bitmapContext = self.createPixelBufferAndBitmapContext(&pixelBuffer) else{
                print("bitmapContext is nil")
                return
            }
            
            self.delegate?.writeBackgroundFrameInContext(contextRef: bitmapContext)
            
            // ensure it's not on main thread
            DispatchQueue.main.sync(execute: {
                UIGraphicsPushContext(bitmapContext)
                
                // write frame here to bitmapContext
                if let viewToCapture = self.viewToCapture{
                    if self.runBenchmark {
                        let startTime = CFAbsoluteTimeGetCurrent()
                        viewToCapture.drawHierarchy(in: viewToCapture.bounds, afterScreenUpdates: false)
                        self.numberOfFramesCaptured += 1
                        if self.numberOfFramesCaptured > INITIALFRAMESTOIGNOREFORBENCHMARK {
                            let currentFrameTime = CFAbsoluteTimeGetCurrent() - startTime
                            self.totalFrameTimeDuringCapture += currentFrameTime
                            print("runBenchmark: Average frame time : \(self.averageFrameDurationDuringCapture()) ms")
                        }
                    } else {
                        viewToCapture.drawHierarchy(in: viewToCapture.bounds, afterScreenUpdates: false)
                    }
                }else{
                    if self.runBenchmark {
                        let startTime = CFAbsoluteTimeGetCurrent()
                        for window in UIApplication.shared.windows {
                            window.drawHierarchy(in: CGRect(x: 0, y: 0, width: self.viewSize.width*self.scale, height: self.viewSize.height*self.scale), afterScreenUpdates: false)
                        }
                        self.numberOfFramesCaptured += 1
                        if self.numberOfFramesCaptured > INITIALFRAMESTOIGNOREFORBENCHMARK {
                            let currentFrameTime = CFAbsoluteTimeGetCurrent() - startTime
                            self.totalFrameTimeDuringCapture += currentFrameTime
                            print("runBenchmark: Average frame time : \(self.averageFrameDurationDuringCapture()) ms")
                        }
                    } else {
                        for window in UIApplication.shared.windows {
                            window.drawHierarchy(in: CGRect(x: 0, y: 0, width: self.viewSize.width*self.scale, height: self.viewSize.height*self.scale), afterScreenUpdates: false)
                        }
                    }
                }
                // write frame here
                
                UIGraphicsPopContext()
                
                guard let pixelBuffer = pixelBuffer else{
                    print("pixelBuffer is nil")
                    return
                }
                if self._pixelAppendSemaphore.wait(timeout: DispatchTime.now()) == .success{
                    self._append_pixelBuffer_queue.async(execute: {
                        let success = self.avAdaptor?.append(pixelBuffer, withPresentationTime: time)
                        if success == false{
                            print(pixelBuffer)
                            print(self.avAdaptor as Any)
                            print("Warning: Unable to write buffer to video")
                        }
                        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
                        self._pixelAppendSemaphore.signal()
                    })
                } else {
                    //假如正在处理，就直接丢弃这一帧
                    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
                }
            })
            self._frameRenderingSemaphore.signal()
        }
    }
    
    fileprivate func createPixelBufferAndBitmapContext( _ pixelBuffer: inout CVPixelBuffer?) -> CGContext? {
        guard let outputBufferPool = self.outputBufferPool else {
            print("error:createPixelBufferAndBitmapContext")
            return nil
        }
        CVPixelBufferPoolCreatePixelBuffer(nil, outputBufferPool, &pixelBuffer)
        if let pixelBuffer = pixelBuffer {
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
        }
        var bitmapContext: CGContext? = nil
        if let pixelBuffer = pixelBuffer {
            bitmapContext = CGContext(data: CVPixelBufferGetBaseAddress(pixelBuffer),
                                      width: CVPixelBufferGetWidth(pixelBuffer),
                                      height: CVPixelBufferGetHeight(pixelBuffer),
                                      bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                                      space: self.rgbColorSpace!,
                                      bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)
        }
        bitmapContext?.scaleBy(x: scale, y: scale)
        let flipVertical = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: self.viewSize.height)
        bitmapContext?.concatenate(flipVertical)
        return bitmapContext
    }
    
    fileprivate func averageFrameDurationDuringCapture() -> Double {
        return (totalFrameTimeDuringCapture / Double((self.numberOfFramesCaptured - INITIALFRAMESTOIGNOREFORBENCHMARK)) * 1000.0)
    }
    
    fileprivate func setUpAudioCapture(){
        guard let device = AVCaptureDevice.default(for: .audio) else {
            print("AVCaptureDevice.default(for: .audio) = nil")
            return
        }
        if !device.isConnected {
            print("AVCaptureDevice Failed")
            return
        }
        
        firstAudioTimeStamp = CMTime.zero

        // add device inputs
        do {
            self.audioCaptureInput = try AVCaptureDeviceInput.init(device: device)
        } catch {
            print(error)
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
        
        audioSettings = audioCaptureOutput!.recommendedAudioSettingsForAssetWriter(writingTo: .mov) as? [String : Any]
        
        // 4. audio
        self.audioInput = AVAssetWriterInput.init(mediaType: .audio, outputSettings: self.audioSettings)
        self.audioInput?.expectsMediaDataInRealTime = true
    }
    
    fileprivate var tempFileURL:URL {
        get{
            let outputPath = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("tmp/screenCapture.mov").absoluteString
            do {
                // delete old video
                try FileManager.default.removeItem(at: URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("tmp/screenCapture.mov"))
            } catch {
                print(error.localizedDescription)
            }
            return URL(string: outputPath)!
        }
    }
}

extension Recorder:AVCaptureAudioDataOutputSampleBufferDelegate{
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection){
        if output == self.audioCaptureOutput {
            if startedAt == nil {
                startedAt = Date()
                firstAudioTimeStamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                self.audioReady = true
                if self.waitToStart {
                    self.videoWriter?.startSession(atSourceTime: self.firstAudioTimeStamp)
                    self.waitToStart = false
                }
            }
            guard self.audioInput != nil else {
                return
            }
            if self.recording && self.audioInput!.isReadyForMoreMediaData {
                if self.recordAudio {
                    self.audioInput!.append(sampleBuffer)
                }
            }
        }
    }
}
