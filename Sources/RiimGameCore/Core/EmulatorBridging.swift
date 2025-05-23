//
//  EmulatorBridging.swift
//  RiimGameCore
//
//  Created by Thanh Vu on 12/5/25.
//
import Foundation

@objc(DLTAEmulatorBridging)
public protocol EmulatorBridging: NSObjectProtocol {
    /// State
    var gameURL: URL? { get }
    
    /// System
    var frameDuration: TimeInterval { get }
    
    /// Audio
    var audioRenderer: AudioRendering? { get set }
    
    /// Video
    var videoRenderer: VideoRendering? { get set }
    
    /// Saves
    var saveUpdateHandler: (() -> Void)? { get set }
    
    
    /// Emulation State
    func start(withGameURL gameURL: URL)
    func stop()
    func pause()
    func resume()
    
    /// Game Loop
    @objc(runFrameAndProcessVideo:) func runFrame(processVideo: Bool)
    
    /// Inputs
    func activateInput(_ input: Int, value: Double, at playerIndex: Int)
    func deactivateInput(_ input: Int, at playerIndex: Int)
    func resetInputs()
    
    /// Save States
    @objc(saveSaveStateToURL:) func saveSaveState(to url: URL)
    @objc(loadSaveStateFromURL:) func loadSaveState(from url: URL)
    
    /// Game Games
    @objc(saveGameSaveToURL:) func saveGameSave(to url: URL)
    @objc(loadGameSaveFromURL:) func loadGameSave(from url: URL)
    
    /// Cheats
    @discardableResult func addCheatCode(_ cheatCode: String, type: String) -> Bool
    func resetCheats()
    func updateCheats()
}

