//
//  VideoRendering.swift
//  
//
//   on 6/29/16.
//  
//

import Foundation
import CoreGraphics

@objc(DLTAVideoRendering)
public protocol VideoRendering: NSObjectProtocol {
    var videoBuffer: UnsafeMutablePointer<UInt8>? { get }
    
    var viewport: CGRect { get set }
    
    func prepare()
    func processFrame()
}
