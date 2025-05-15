//
//  AudioRendering.swift
//  
//
//   on 6/29/16.
//  
//

import Foundation

@objc(DLTAAudioRendering)
public protocol AudioRendering: NSObjectProtocol {
    var audioBuffer: RingBuffer { get }
}
