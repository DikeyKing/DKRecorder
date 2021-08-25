//
//  Dispatch+Extension.swift
//  Oasis
//
//  Created by Dikey on 2019/12/9.
//  Copyright © 2019 Dikey. All rights reserved.
//

import Foundation


public extension DispatchQueue {
    
    private static var _onceTracker = [String]()
    
    /**
     Executes a block of code, associated with a unique token, only once.  The code is thread safe and will
     only execute the code once even in the presence of multithreaded calls.
     
     - parameter token: A unique reverse DNS style name such as com.vectorform.<name> or a GUID
     - parameter block: Block to execute once
     */
    class func once(token: String, block:()->Void) {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }
        
        if _onceTracker.contains(token) {
            return
        }
        
        _onceTracker.append(token)
        block()
    }
    
    class func delay(delay: TimeInterval, closure: @escaping () -> Void) {
        let when = DispatchTime.now() + delay
        DispatchQueue.main.asyncAfter(deadline: when, execute: closure)
    }
    
    class func performAction(after seconds: TimeInterval, callBack: @escaping (() -> Void) ) {
        DispatchQueue.delay(delay: seconds) {
            callBack()
        }
    }
}

@discardableResult
public func synchronized<T>(_ lock: AnyObject, closure:() -> T) -> T {
    objc_sync_enter(lock)
    defer { objc_sync_exit(lock) }
    return closure()
}
