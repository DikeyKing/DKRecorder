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

let INITIALFRAMESTOIGNOREFORBENCHMARK = 5

protocol RecorderProtocol:AnyObject{
    func writeBackgroundFrameInContext(contextRef:CGContext)
}

class Recorder: NSObject {
    //    static let shared = Recorder.init()
    
    weak var delegate:RecorderProtocol?
    
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
    fileprivate var audioSettings: [AnyHashable : Any]?
    fileprivate var firstAudioTimeStamp: CMTime!
    fileprivate var startedAt: Date?
    fileprivate var firstTimeStamp: CFTimeInterval = 0
    
    fileprivate var _audio_capture_queue: DispatchQueue!
    fileprivate var _render_queue: DispatchQueue!
    fileprivate var _append_pixelBuffer_queue: DispatchQueue!
    fileprivate var _frameRenderingSemaphore: DispatchSemaphore!
    fileprivate var _pixelAppendSemaphore: DispatchSemaphore!
    
    fileprivate var viewSize: CGSize = UIApplication.shared.delegate?.window??.bounds.size ?? CGSize.zero
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
        _frameRenderingSemaphore = DispatchSemaphore(value: 1)
        _pixelAppendSemaphore = DispatchSemaphore(value: 1)
        
        setUpAudioCapture()
    }
    
    public func startRecording()->Bool {
        if self.recording {
            self.captureSession?.startRunning()
            self.setUpWriter()
            recording = (self.videoWriter?.status == .writing)
            self.displayLink = CADisplayLink(target: self, selector: #selector(writeVideoFrame))
            self.displayLink?.add(to: RunLoop.main , forMode: .common)
        }
        return self.recording
    }
    
    public func stopRecording(resultCallback:@escaping(_ result:URL?)->()?){
        if self.recording{
            self.captureSession?.stopRunning()
            self.recording = false
            self.displayLink?.remove(from: RunLoop.main, forMode: .common)
            self.completeRecordingSession(completionCallback: resultCallback)
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
            kCVPixelBufferWidthKey as String: Int(self.viewSize.width * self.scale),
            kCVPixelBufferHeightKey as String: Int(self.viewSize.height * self.scale),
            kCVPixelBufferBytesPerRowAlignmentKey as String: Int(self.viewSize.width * self.viewSize.height * self.scale)
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, outputBufferAttributes as NSDictionary?, &_outputBufferPool);
        
        let fileURL:URL = self.videoURL ?? self.tempFileURL
        guard let videoWriter = try? AVAssetWriter.init(outputURL: fileURL, fileType: .mov) else {
            fatalError("AVAssetWriter error")
        }
        self.videoWriter = videoWriter
        
        let pixelNumber = self.viewSize.width * self.viewSize.height * scale * self.scale
        let videoCompression = [
            AVVideoAverageBitRateKey: NSNumber(value: Double(pixelNumber) * 11.4)
        ]
        let outputSettings = [AVVideoCodecKey : AVVideoCodecType.h264,
                              AVVideoWidthKey : NSNumber(value: Float(self.viewSize.width * self.scale)),
                              AVVideoHeightKey : NSNumber(value: Float(self.viewSize.height * self.scale)),
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
    
    @objc fileprivate func writeVideoFrame(){
        // http://stackoverflow.com/a/5956119
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
                            window.drawHierarchy(in: CGRect(x: 0, y: 0, width: self.viewSize.width, height: self.viewSize.height), afterScreenUpdates: false)
                        }
                        self.numberOfFramesCaptured += 1
                        if self.numberOfFramesCaptured > INITIALFRAMESTOIGNOREFORBENCHMARK {
                            let currentFrameTime = CFAbsoluteTimeGetCurrent() - startTime
                            self.totalFrameTimeDuringCapture += currentFrameTime
                            print("runBenchmark: Average frame time : \(self.averageFrameDurationDuringCapture()) ms")
                        }
                    } else {
                        for window in UIApplication.shared.windows {
                            window.drawHierarchy(in: CGRect(x: 0, y: 0, width: self.viewSize.width, height: self.viewSize.height), afterScreenUpdates: false)
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
                        //一直等待
                        let success = self.avAdaptor?.append(pixelBuffer, withPresentationTime: time)
                        if success == false{
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
        }
    }
    
    fileprivate func createPixelBufferAndBitmapContext( _ pixelBuffer: inout CVPixelBuffer?) -> CGContext? {
        CVPixelBufferPoolCreatePixelBuffer(nil, self._outputBufferPool!, &pixelBuffer)
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
                                      space: self._rgbColorSpace!,
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
        if device.isConnected {
            print("Connected Device: \(device.localizedName )")
        } else {
            print("AVCaptureDevice Failed")
            return
        }
        
        // add device inputs
        do {
            self.audioCaptureInput = try AVCaptureDeviceInput(device: device)
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
}

extension Recorder:AVCaptureAudioDataOutputSampleBufferDelegate{
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection){
        if output == self.audioCaptureOutput {
            if startedAt == nil {
                startedAt = Date()
                firstAudioTimeStamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            }
            guard self.audioInput != nil else {
                return
            }
            if self.recording && self.audioInput!.isReadyForMoreMediaData {
                self.audioInput!.append(sampleBuffer)
            }
        }
    }
}
