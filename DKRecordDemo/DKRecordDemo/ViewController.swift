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

    var animationViews = [UIView].init()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        self.addAnimationViews()
        self.playAnimation()
    }
    
}

