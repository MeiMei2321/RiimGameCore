//
//  RiimGBAEmulator.swift
//  RiimGameCore
//
//  Created by Thanh Vu on 12/5/25.
//

import Foundation
@_exported import RiimGBAGameBridge

public struct RiimGBAEmulator {
    public let bridge = mGBAEmulatorBridge.shared

    public init() {
        
    }
}
