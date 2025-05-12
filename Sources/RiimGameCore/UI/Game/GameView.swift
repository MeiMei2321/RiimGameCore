//
//  GameView.swift
//  DeltaCore
//
//  Created by Riley Testut on 3/16/15.
//  Copyright (c) 2015 Riley Testut. All rights reserved.
//

import UIKit
import CoreImage
import MetalKit
import AVFoundation

public enum SamplerMode {
    case linear
    case nearestNeighbor
}

public class GameView: UIView {
    public var isEnabled: Bool = true
    public var isTouchScreen: Bool = false
    private var didRenderInitialFrame: Bool = false
    private var isRenderingInitialFrame: Bool = false
    
    // Set to limit rendering to just a specific VideoManager.
    public weak var exclusiveVideoManager: VideoManager?
    
    @NSCopying public var inputImage: CIImage? {
        didSet {
            if self.inputImage?.extent != oldValue?.extent
            {
                DispatchQueue.main.async {
                    self.setNeedsLayout()
                }
            }
            
            self.update()
        }
    }
    
    @NSCopying public var filter: CIFilter? {
        didSet {
            guard self.filter != oldValue else { return }
            self.update()
        }
    }
    
    public var samplerMode: SamplerMode = .nearestNeighbor {
        didSet {
            self.update()
        }
    }
    
    public var outputImage: CIImage? {
        guard let inputImage = self.inputImage else { return nil }
        
        var image: CIImage?
        
        switch self.samplerMode
        {
        case .linear: image = inputImage.samplingLinear()
        case .nearestNeighbor: image = inputImage.samplingNearest()
        }
                
        if let filter = self.filter
        {
            filter.setValue(image, forKey: kCIInputImageKey)
            image = filter.outputImage
        }
        
        return image
    }
    
    private lazy var context: CIContext = self.makeContext()
        
    private let mtkView: MTKView
    private let metalDevice = MTLCreateSystemDefaultDevice()
    private lazy var metalCommandQueue = self.metalDevice?.makeCommandQueue()
    private weak var metalLayer: CAMetalLayer?
    
    private var lock = os_unfair_lock()
    private var didLayoutSubviews = false
    
    public override init(frame: CGRect)
    {
        self.mtkView = MTKView(frame: .zero, device: self.metalDevice)
        
        super.init(frame: frame)
        
        self.initialize()
    }
    
    public required init?(coder aDecoder: NSCoder)
    {
        self.mtkView = MTKView(frame: .zero, device: self.metalDevice)
        
        super.init(coder: aDecoder)
        
        self.initialize()
    }
    
    private func initialize()
    {
        self.mtkView.frame = self.bounds
        self.mtkView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        self.mtkView.delegate = self
        self.mtkView.enableSetNeedsDisplay = false
        self.mtkView.framebufferOnly = false // Must be false to avoid "frameBufferOnly texture not supported for compute" assertion
        self.mtkView.isPaused = true
        self.mtkView.clipsToBounds = true
        self.addSubview(self.mtkView)

        if let metalLayer = self.mtkView.layer as? CAMetalLayer
        {
            self.metalLayer = metalLayer
        }
        
        self.layer.shadowColor = UIColor.black.cgColor
        self.layer.shadowOffset = CGSize(width: 0, height: 3)
        self.layer.shadowRadius = 9
        self.layer.shadowOpacity = 0
        
        self.layer.borderColor = UIColor.white.withAlphaComponent(0.2).cgColor
        self.layer.borderWidth = 0
    }
    
    public override func didMoveToWindow()
    {
        if let window = self.window
        {
            self.mtkView.contentScaleFactor = window.screen.scale
            self.update()
        }
    }
    
    public override func layoutSubviews()
    {
        super.layoutSubviews()
        
        self.mtkView.isHidden = (self.outputImage == nil)
        
        self.didLayoutSubviews = true
    }
}

public extension GameView
{
    func snapshot() -> UIImage?
    {
        // Unfortunately, rendering CIImages doesn't always work when backed by an OpenGLES texture.
        // As a workaround, we simply render the view itself into a graphics context the same size
        // as our output image.
        //
        // let cgImage = self.context.createCGImage(outputImage, from: outputImage.extent)
        
        guard let outputImage = self.outputImage else { return nil }

        let rect = CGRect(origin: .zero, size: outputImage.extent.size)
        
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true
        
        let renderer = UIGraphicsImageRenderer(size: rect.size, format: format)
        
        let snapshot = renderer.image { (context) in
            self.mtkView.drawHierarchy(in: rect, afterScreenUpdates: false)
        }
        
        return snapshot
    }
}

private extension GameView {
    func makeContext() -> CIContext {
        guard let metalCommandQueue else {
            // This should never be called, but just in case we return dummy CIContext.
            return CIContext(options: [.workingColorSpace: NSNull()])
        }

        let options: [CIContextOption: Any] = [.workingColorSpace: NSNull(),
                                               .cacheIntermediates: true,
                                               .name: "GameView Context"]

        let context = CIContext(mtlCommandQueue: metalCommandQueue, options: options)
        return context
    }
    
    func update()
    {
        // Calling display when outputImage is nil may crash for OpenGLES-based rendering.
        guard self.isEnabled && self.outputImage != nil else { return }
        
        os_unfair_lock_lock(&self.lock)
        defer { os_unfair_lock_unlock(&self.lock) }
        
        // layoutSubviews() must be called after setting self.eaglContext before we can display anything.
        // Otherwise, the app may crash due to race conditions when creating framebuffer from background thread.
        guard self.didLayoutSubviews else { return }

        if !self.didRenderInitialFrame
        {
            if Thread.isMainThread
            {
                self.mtkView.draw()
                self.didRenderInitialFrame = true
            }
            else if !self.isRenderingInitialFrame
            {
                // Make sure we don't make multiple calls to glkView.display() before first call returns.
                self.isRenderingInitialFrame = true

                DispatchQueue.main.async {
                    self.mtkView.draw()
                    self.didRenderInitialFrame = true
                    self.isRenderingInitialFrame = false
                }
            }
        }
        else
        {
            self.mtkView.draw()
        }
    }
}

extension GameView: MTKViewDelegate
{
    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    public func draw(in view: MTKView)
    {
        autoreleasepool {
            guard let image = self.outputImage,
                  let commandBuffer = self.metalCommandQueue?.makeCommandBuffer(),
                  let currentDrawable = self.metalLayer?.nextDrawable()
            else { return }

            let scaleX = view.drawableSize.width / image.extent.width
            let scaleY = view.drawableSize.height / image.extent.height
            let outputImage = image.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

            do
            {
                let destination = CIRenderDestination(width: Int(view.drawableSize.width),
                                                      height: Int(view.drawableSize.height),
                                                      pixelFormat: view.colorPixelFormat,
                                                      commandBuffer: nil) { [unowned currentDrawable] () -> MTLTexture in
                    // Lazily return texture to prevent hangs due to waiting for previous command to finish.
                    let texture = currentDrawable.texture
                    return texture
                }

                try self.context.startTask(toRender: outputImage, from: outputImage.extent, to: destination, at: .zero)

                commandBuffer.present(currentDrawable)
                commandBuffer.commit()
            }
            catch
            {
                print("Failed to render frame with Metal.", error)
            }
        }
    }
}
