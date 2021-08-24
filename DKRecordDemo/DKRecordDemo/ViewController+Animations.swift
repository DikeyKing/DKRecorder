//
//  ViewController+Animations.swift
//  DKRecordDemo
//
//  Created by Dikey on 2021/8/9.
//  Copyright © 2021 Dikey. All rights reserved.
//

import Foundation
import UIKit

extension CGPoint{
    static func generateRandomPointInScreen()->CGPoint{
        let x = CGFloat(arc4random()%UInt32(UIScreen.main.bounds.size.width))
        let y = CGFloat(arc4random()%UInt32(UIScreen.main.bounds.size.height))
        return CGPoint.init(x: x, y: y)
    }
}

extension ViewController{
    
    func addAnimationViews() {
        let color = UIColor.random()
        for _ in 1...10 {
            let randomInt = Int.random(in: 0..<2)
            if randomInt == AnimationViews.circle.rawValue {
                let circleView = UIView.init(frame: CGRect.init(x: 0,y: 0,width: 50, height: 50))
                circleView.center = CGPoint.generateRandomPointInScreen()
                circleView.layer.cornerRadius = 50/2.0
                circleView.layer.borderWidth = 3
                circleView.layer.borderColor = color.cgColor
                circleView.backgroundColor = color
                view.addSubview(circleView)
                animationViews.append(circleView)
            }else if randomInt == AnimationViews.triangle.rawValue {
                let triangle = TriangleView(frame: CGRect(x: 20, y: 40, width: 50 , height: 60))
                triangle.center = CGPoint.generateRandomPointInScreen()
                triangle.backgroundColor = .clear
                view.addSubview(triangle)
                animationViews.append(triangle)
            }else if randomInt == AnimationViews.square.rawValue {
                let square = UIView.init(frame: CGRect.init(x: 0,y: 0,width: 45, height: 45))
                square.center = CGPoint.generateRandomPointInScreen()
                square.backgroundColor = UIColor.random()
                view.addSubview(square)
                animationViews.append(square)
            }
        }
    }
    
    func playAnimation() {
        let randomTime = Double.random(in: 5..<10)
        UIView.animate(withDuration: randomTime, delay: 0.0, options: [.curveLinear]) {
            for view in self.animationViews {
                view.center = CGPoint.generateRandomPointInScreen()
            }
        } completion: { _ in
            self.playAnimation()
        }
    }
    
}
