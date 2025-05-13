//
//  VideoProcessor.swift
//  RiimGameCore
//
//  Created by Thanh Vu on 13/5/25.
//
import Foundation
import UIKit

public protocol VideoProcessor {
    var videoFormat: VideoFormat { get }
    var videoBuffer: UnsafeMutablePointer<UInt8>? { get }
    
    var viewport: CGRect { get set }
    
    func prepare()
    func processFrame() -> CIImage?
}

public extension VideoProcessor {
    var correctedViewport: CGRect? {
        guard self.viewport != .zero else { return nil }
        
        let viewport = CGRect(x: self.viewport.minX, y: self.videoFormat.dimensions.height - self.viewport.height,
                              width: self.viewport.width, height: self.viewport.height)
        return viewport
    }
}
