//
//  ViewController.swift
//  DKRecordDemo
//
//  Created by Dikey on 2020/1/18.
//  Copyright © 2020 Dikey. All rights reserved.
//

import UIKit

enum AnimationViews:Int {
    case circle = 0
    case triangle = 1
    case square = 2
}

class ViewController: UIViewController {

    let recorder = DKRecorder.init()
    var animationViews = [UIView].init()

    override func viewDidLoad() {
        super.viewDidLoad()
        self.addAnimationViews()
        self.playAnimation()
        
        let tap = UITapGestureRecognizer(target: self, action: #selector(self.recordAction(_:)))
        tap.cancelsTouchesInView = true
        self.view.addGestureRecognizer(tap)
    }
    
    @objc func recordAction(_ sender: UITapGestureRecognizer? = nil) {
        if self.recorder.recording == false {
//            self.recorder.runBenchmark = true
            // add NSMicrophoneUsageDescription key to app's Info.plist if recordAudio = true
             self.recorder.recordAudio = true
            
            self.recorder.startRecording()
            self.recorder.viewToCapture = self.view
            self.recorder.writeToPhotoLibrary = true
            print("startRecording")
        }else{
            self.view.isUserInteractionEnabled = false
            self.recorder.stopRecording {url in
                self.view.isUserInteractionEnabled = true
                print("stopRecording url = \(url as Any)")
            }
        }
    }
    
}
