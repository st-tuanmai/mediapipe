
import CoreMedia
import CoreVideo
import Metal
import UIKit
import MetalPerformanceShaders
import MetalKit

class Render {
  
  var description: String = "Metal"
  
  var isPrepared = false
  
  private(set) var inputFormatDescription: CMFormatDescription?
  
  private(set) var outputFormatDescription: CMFormatDescription?
  
  private var outputPixelBufferPool: CVPixelBufferPool?
  
  private let metalDevice = MTLCreateSystemDefaultDevice()!
  
  private var computePipelineState: MTLComputePipelineState?

  private let image2 = UIImage(named: "bg1.jpeg")!

  var inputTexture2: MTLTexture?

  private var textureCache: CVMetalTextureCache!
  let context: CIContext

  let textureLoader: MTKTextureLoader

  private lazy var commandQueue: MTLCommandQueue? = {
    return self.metalDevice.makeCommandQueue()
  }()
  
  required init() {
    let defaultLibrary = metalDevice.makeDefaultLibrary()!
    let kernelFunction = defaultLibrary.makeFunction(name: "drawWithInvertedColor")
    do {
      computePipelineState = try metalDevice.makeComputePipelineState(function: kernelFunction!)
    } catch {
      print("Could not create pipeline state: \(error)")
    }
    context =  CIContext(mtlDevice: metalDevice)
    textureLoader = MTKTextureLoader(device: metalDevice)
    inputTexture2 = try? textureLoader.newTexture(cgImage: image2.cgImage!)
  }
  
  func prepare(with formatDescription: CMFormatDescription,
               outputRetainedBufferCountHint: Int,
               needChangeWidthHeight: Bool = false) {
    reset()
    
    (outputPixelBufferPool, _, outputFormatDescription) = allocateOutputBufferPool(with: formatDescription,
                                                                                   outputRetainedBufferCountHint: outputRetainedBufferCountHint, needChangeWidthHeight: needChangeWidthHeight)
    if outputPixelBufferPool == nil {
      return
    }
    inputFormatDescription = formatDescription
    
    var metalTextureCache: CVMetalTextureCache?
    if CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, metalDevice, nil, &metalTextureCache) != kCVReturnSuccess {
      assertionFailure("Unable to allocate texture cache")
    } else {
      textureCache = metalTextureCache
    }
    
    isPrepared = true
  }
  
  func reset() {
    outputPixelBufferPool = nil
    outputFormatDescription = nil
    inputFormatDescription = nil
    textureCache = nil
    isPrepared = false
  }

  func render(image: UIImage, segmentDatas: UnsafePointer<Float32>?) -> UIImage? {
    guard let segmentDatas = segmentDatas else {
      print("segmentDatas not found")
      return nil
    }

    var inputTexture: MTLTexture!
    do {
      guard let cgImage = image.fixOrientationCGimage() else { return nil }
      print(cgImage.width)
      print(cgImage.height)
      inputTexture = try textureLoader.newTexture(cgImage: cgImage)
    } catch {
      print(error)
      return nil
    }

    print(inputTexture.width)
    print(inputTexture.height)
    let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: inputTexture.width, height: inputTexture.height, mipmapped: false)
    textureDescriptor.usage = .unknown
    let inputScaleTexture = metalDevice.makeTexture(descriptor: textureDescriptor)

    resizeTexture(sourceTexture: inputTexture2!, desTexture: inputScaleTexture!, targetSize: MTLSize(width: inputTexture.width, height: inputTexture.height, depth: 1), resizeMode: .scaleToFill)

    // Set up command queue, buffer, and encoder.
    guard let commandQueue = commandQueue,
          let commandBuffer = commandQueue.makeCommandBuffer(),
          let commandEncoder = commandBuffer.makeComputeCommandEncoder() else {
      print("Failed to create a Metal command queue.")
      CVMetalTextureCacheFlush(textureCache!, 0)
      return nil
    }

    let outputTexture = metalDevice.makeTexture(descriptor: textureDescriptor)

    commandEncoder.label = "Demo Metal"
    commandEncoder.setComputePipelineState(computePipelineState!)
    commandEncoder.setTexture(inputTexture, index: 0)
    commandEncoder.setTexture(inputScaleTexture, index: 1)
    commandEncoder.setTexture(outputTexture, index: 2)
    let buffer = metalDevice.makeBuffer(bytes: segmentDatas, length: inputTexture.width * inputTexture.height * MemoryLayout<Float32>.size)!
    commandEncoder.setBuffer(buffer, offset: 0, index: 0)

    // Set up the thread groups.
    let width = computePipelineState!.threadExecutionWidth
    let height = computePipelineState!.maxTotalThreadsPerThreadgroup / width
    let threadsPerThreadgroup = MTLSizeMake(width, height, 1)
    let threadgroupsPerGrid = MTLSize(width: (inputTexture.width + width - 1) / width,
                                      height: (inputTexture.height + height - 1) / height,
                                      depth: 1)
    commandEncoder.dispatchThreadgroups(threadgroupsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)

    commandEncoder.endEncoding()
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()
    guard let ciImage = CIImage(mtlTexture: outputTexture!) else { return nil }
    return UIImage(ciImage: ciImage)

  }

  func render(cgImage: CGImage, segmentDatas: UnsafePointer<Float32>?) -> CVPixelBuffer? {

    guard let segmentDatas = segmentDatas, isPrepared else {
      print("segmentDatas not found")
      return nil
    }

    var newPixelBuffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, outputPixelBufferPool!, &newPixelBuffer)
    guard let outputPixelBuffer = newPixelBuffer else {
      print("Allocation failure: Could not get pixel buffer from pool. (\(self.description))")
      return nil
    }
    guard let outputTexture = makeTextureFromCVPixelBuffer(pixelBuffer: outputPixelBuffer, textureFormat: .bgra8Unorm) else {
      return nil
    }
    var inputTexture: MTLTexture!
    do {
      inputTexture = try textureLoader.newTexture(cgImage: cgImage)
    } catch {
      print(error)
      return nil
    }

    let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: inputTexture.width, height: inputTexture.height, mipmapped: false)
    textureDescriptor.usage = .unknown
    let inputScaleTexture = metalDevice.makeTexture(descriptor: textureDescriptor)

    resizeTexture(sourceTexture: inputTexture2!, desTexture: inputScaleTexture!, targetSize: MTLSize(width: inputTexture.width, height: inputTexture.height, depth: 1), resizeMode: .scaleToFill)

    // Set up command queue, buffer, and encoder.
    guard let commandQueue = commandQueue,
          let commandBuffer = commandQueue.makeCommandBuffer(),
          let commandEncoder = commandBuffer.makeComputeCommandEncoder() else {
      print("Failed to create a Metal command queue.")
      CVMetalTextureCacheFlush(textureCache!, 0)
      return nil
    }

    commandEncoder.label = "Demo Metal"
    commandEncoder.setComputePipelineState(computePipelineState!)
    commandEncoder.setTexture(inputTexture, index: 0)
    commandEncoder.setTexture(inputScaleTexture, index: 1)
    commandEncoder.setTexture(outputTexture, index: 2)
    let buffer = metalDevice.makeBuffer(bytes: segmentDatas, length: inputTexture.width * inputTexture.height * MemoryLayout<Float32>.size)!
    commandEncoder.setBuffer(buffer, offset: 0, index: 0)

    // Set up the thread groups.
    let width = computePipelineState!.threadExecutionWidth
    let height = computePipelineState!.maxTotalThreadsPerThreadgroup / width
    let threadsPerThreadgroup = MTLSizeMake(width, height, 1)
    let threadgroupsPerGrid = MTLSize(width: (inputTexture.width + width - 1) / width,
                                      height: (inputTexture.height + height - 1) / height,
                                      depth: 1)
    commandEncoder.dispatchThreadgroups(threadgroupsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)

    commandEncoder.endEncoding()
    commandBuffer.commit()
    return outputPixelBuffer
  }

  func getCGImmage(ciImage: CIImage) -> CGImage {
    guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { fatalError("error") }
    return cgImage
  }

  func render(ciImage: CIImage, segmentDatas: UnsafePointer<Float32>?) -> CVPixelBuffer? {

    guard let segmentDatas = segmentDatas, isPrepared else {
      print("segmentDatas not found")
      return nil
    }

    var newPixelBuffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, outputPixelBufferPool!, &newPixelBuffer)
    guard let outputPixelBuffer = newPixelBuffer else {
      print("Allocation failure: Could not get pixel buffer from pool. (\(self.description))")
      return nil
    }
    guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { fatalError("error") }
    print(cgImage.width, cgImage.height)

    guard let outputTexture = makeTextureFromCVPixelBuffer(pixelBuffer: outputPixelBuffer, textureFormat: .bgra8Unorm) else {
      return nil
    }
    var inputTexture: MTLTexture!
    do {
      inputTexture = try textureLoader.newTexture(cgImage: cgImage)
    } catch {
      print(error)
      return nil
    }
    let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: inputTexture.width, height: inputTexture.height, mipmapped: false)
    textureDescriptor.usage = .unknown
    let inputScaleTexture = metalDevice.makeTexture(descriptor: textureDescriptor)

    resizeTexture(sourceTexture: inputTexture2!, desTexture: inputScaleTexture!, targetSize: MTLSize(width: inputTexture.width, height: inputTexture.height, depth: 1), resizeMode: .scaleToFill)

    // Set up command queue, buffer, and encoder.
    guard let commandQueue = commandQueue,
          let commandBuffer = commandQueue.makeCommandBuffer(),
          let commandEncoder = commandBuffer.makeComputeCommandEncoder() else {
      print("Failed to create a Metal command queue.")
      CVMetalTextureCacheFlush(textureCache!, 0)
      return nil
    }

    commandEncoder.label = "Demo Metal"
    commandEncoder.setComputePipelineState(computePipelineState!)
    commandEncoder.setTexture(inputTexture, index: 0)
    commandEncoder.setTexture(inputScaleTexture, index: 1)
    commandEncoder.setTexture(outputTexture, index: 2)
    let buffer = metalDevice.makeBuffer(bytes: segmentDatas, length: inputTexture.width * inputTexture.height * MemoryLayout<Float32>.size)!
    commandEncoder.setBuffer(buffer, offset: 0, index: 0)

    // Set up the thread groups.
    let width = computePipelineState!.threadExecutionWidth
    let height = computePipelineState!.maxTotalThreadsPerThreadgroup / width
    let threadsPerThreadgroup = MTLSizeMake(width, height, 1)
    let threadgroupsPerGrid = MTLSize(width: (inputTexture.width + width - 1) / width,
                                      height: (inputTexture.height + height - 1) / height,
                                      depth: 1)
    commandEncoder.dispatchThreadgroups(threadgroupsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)

    commandEncoder.endEncoding()
    commandBuffer.commit()
    return outputPixelBuffer
  }

  func render(pixelBuffer: CVPixelBuffer, segmentDatas: UnsafePointer<Float32>?) -> CVPixelBuffer? {
    
    guard let segmentDatas = segmentDatas, isPrepared else {
      print("segmentDatas not found")
      return nil
    }
    
    var newPixelBuffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, outputPixelBufferPool!, &newPixelBuffer)
    guard let outputPixelBuffer = newPixelBuffer else {
      print("Allocation failure: Could not get pixel buffer from pool. (\(self.description))")
      return nil
    }
    guard let inputTexture = makeTextureFromCVPixelBuffer(pixelBuffer: pixelBuffer, textureFormat: .bgra8Unorm),
          let outputTexture = makeTextureFromCVPixelBuffer(pixelBuffer: outputPixelBuffer, textureFormat: .bgra8Unorm) else {
      return nil
    }

    let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: inputTexture.width, height: inputTexture.height, mipmapped: false)
    textureDescriptor.usage = .unknown
    let inputScaleTexture = metalDevice.makeTexture(descriptor: textureDescriptor)
    
    resizeTexture(sourceTexture: inputTexture2!, desTexture: inputScaleTexture!, targetSize: MTLSize(width: inputTexture.width, height: inputTexture.height, depth: 1), resizeMode: .scaleToFill)
    
    // Set up command queue, buffer, and encoder.
    guard let commandQueue = commandQueue,
          let commandBuffer = commandQueue.makeCommandBuffer(),
          let commandEncoder = commandBuffer.makeComputeCommandEncoder() else {
      print("Failed to create a Metal command queue.")
      CVMetalTextureCacheFlush(textureCache!, 0)
      return nil
    }
    
    commandEncoder.label = "Demo Metal"
    commandEncoder.setComputePipelineState(computePipelineState!)
    commandEncoder.setTexture(inputTexture, index: 0)
    commandEncoder.setTexture(inputScaleTexture, index: 1)
    commandEncoder.setTexture(outputTexture, index: 2)
    let buffer = metalDevice.makeBuffer(bytes: segmentDatas, length: inputTexture.width * inputTexture.height * MemoryLayout<Float32>.size)!
    commandEncoder.setBuffer(buffer, offset: 0, index: 0)
    
    // Set up the thread groups.
    let width = computePipelineState!.threadExecutionWidth
    let height = computePipelineState!.maxTotalThreadsPerThreadgroup / width
    let threadsPerThreadgroup = MTLSizeMake(width, height, 1)
    let threadgroupsPerGrid = MTLSize(width: (inputTexture.width + width - 1) / width,
                                      height: (inputTexture.height + height - 1) / height,
                                      depth: 1)
    commandEncoder.dispatchThreadgroups(threadgroupsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
    
    commandEncoder.endEncoding()
    commandBuffer.commit()
    return outputPixelBuffer
  }
  
  func resizeTexture(sourceTexture: MTLTexture, desTexture: MTLTexture, targetSize:MTLSize, resizeMode: UIView.ContentMode) {
    guard let queue = self.commandQueue,
          let commandBuffer = queue.makeCommandBuffer() else {
      print("FrameMixer resizeTexture command buffer create failed")
      return
    }
    
    let device = queue.device;
    
    // Scale texture
    let sourceWidth = sourceTexture.width
    let sourceHeight = sourceTexture.height
    let widthRatio: Double = Double(targetSize.width) / Double(sourceWidth)
    let heightRatio: Double = Double(targetSize.height) / Double(sourceHeight)
    var scaleX: Double = 0;
    var scaleY: Double  = 0;
    var translateX: Double = 0;
    var translateY: Double = 0;
    if resizeMode == .scaleToFill {
      //ScaleFill
      scaleX = Double(targetSize.width) / Double(sourceWidth)
      scaleY = Double(targetSize.height) / Double(sourceHeight)
      
    } else if resizeMode == .scaleAspectFit {
      //AspectFit
      if heightRatio > widthRatio {
        scaleX = Double(targetSize.width) / Double(sourceWidth)
        scaleY = scaleX
        let currentHeight = Double(sourceHeight) * scaleY
        translateY = (Double(targetSize.height) - currentHeight) * 0.5
      } else {
        scaleY = Double(targetSize.height) / Double(sourceHeight)
        scaleX = scaleY
        let currentWidth = Double(sourceWidth) * scaleX
        translateX = (Double(targetSize.width) - currentWidth) * 0.5
      }
    } else if resizeMode == .scaleAspectFill {
      //AspectFill
      if heightRatio > widthRatio {
        scaleY = Double(targetSize.height) / Double(sourceHeight)
        scaleX = scaleY
        let currentWidth = Double(sourceWidth) * scaleX
        translateX = (Double(targetSize.width) - currentWidth) * 0.5
        
      } else {
        scaleX = Double(targetSize.width) / Double(sourceWidth)
        scaleY = scaleX
        let currentHeight = Double(sourceHeight) * scaleY
        translateY = (Double(targetSize.height) - currentHeight) * 0.5
      }
    }
    var transform = MPSScaleTransform(scaleX: scaleX, scaleY: scaleY, translateX: translateX, translateY: translateY)
    if #available(iOS 11.0, *) {
      let scale = MPSImageBilinearScale.init(device: device)
      withUnsafePointer(to: &transform) { (transformPtr: UnsafePointer<MPSScaleTransform>) -> () in
        scale.scaleTransform = transformPtr
        scale.encode(commandBuffer: commandBuffer, sourceTexture: sourceTexture, destinationTexture: desTexture)
      }
    } else {
      print("Frame mixer resizeTexture failed, only support iOS 11.0")
    }
    
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()
  }
  
  func makeTextureFromCVPixelBuffer(pixelBuffer: CVPixelBuffer, textureFormat: MTLPixelFormat) -> MTLTexture? {
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    
    // Create a Metal texture from the image buffer.
    var cvTextureOut: CVMetalTexture?
    CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, pixelBuffer, nil, textureFormat, width, height, 0, &cvTextureOut)
    
    guard let cvTexture = cvTextureOut, let texture = CVMetalTextureGetTexture(cvTexture) else {
      CVMetalTextureCacheFlush(textureCache, 0)
      return nil
    }
    return texture
  }
}

func allocateOutputBufferPool(with inputFormatDescription: CMFormatDescription, outputRetainedBufferCountHint: Int, needChangeWidthHeight: Bool) ->(
  outputBufferPool: CVPixelBufferPool?,
  outputColorSpace: CGColorSpace?,
  outputFormatDescription: CMFormatDescription?) {
    
    let inputMediaSubType = CMFormatDescriptionGetMediaSubType(inputFormatDescription)
    if inputMediaSubType != kCVPixelFormatType_32BGRA {
      assertionFailure("Invalid input pixel buffer type \(inputMediaSubType)")
      return (nil, nil, nil)
    }
    
    let inputDimensions = CMVideoFormatDescriptionGetDimensions(inputFormatDescription)
    var width = inputDimensions.width
    var height = inputDimensions.height
    if needChangeWidthHeight {
      width = height
      height = inputDimensions.width
    }
    var pixelBufferAttributes: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: UInt(inputMediaSubType),
      kCVPixelBufferWidthKey as String: Int(width),
      kCVPixelBufferHeightKey as String: Int(height),
      kCVPixelBufferIOSurfacePropertiesKey as String: [:]
    ]
    
    // Get pixel buffer attributes and color space from the input format description.
    var cgColorSpace = CGColorSpaceCreateDeviceRGB()
    if let inputFormatDescriptionExtension = CMFormatDescriptionGetExtensions(inputFormatDescription) as Dictionary? {
      let colorPrimaries = inputFormatDescriptionExtension[kCVImageBufferColorPrimariesKey]
      
      if let colorPrimaries = colorPrimaries {
        var colorSpaceProperties: [String: AnyObject] = [kCVImageBufferColorPrimariesKey as String: colorPrimaries]
        
        if let yCbCrMatrix = inputFormatDescriptionExtension[kCVImageBufferYCbCrMatrixKey] {
          colorSpaceProperties[kCVImageBufferYCbCrMatrixKey as String] = yCbCrMatrix
        }
        
        if let transferFunction = inputFormatDescriptionExtension[kCVImageBufferTransferFunctionKey] {
          colorSpaceProperties[kCVImageBufferTransferFunctionKey as String] = transferFunction
        }
        
        pixelBufferAttributes[kCVBufferPropagatedAttachmentsKey as String] = colorSpaceProperties
      }
      
      if let cvColorspace = inputFormatDescriptionExtension[kCVImageBufferCGColorSpaceKey] {
        cgColorSpace = cvColorspace as! CGColorSpace
      } else if (colorPrimaries as? String) == (kCVImageBufferColorPrimaries_P3_D65 as String) {
        cgColorSpace = CGColorSpace(name: CGColorSpace.displayP3)!
      }
    }
    
    // Create a pixel buffer pool with the same pixel attributes as the input format description.
    let poolAttributes = [kCVPixelBufferPoolMinimumBufferCountKey as String: outputRetainedBufferCountHint]
    var cvPixelBufferPool: CVPixelBufferPool?
    CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttributes as NSDictionary?, pixelBufferAttributes as NSDictionary?, &cvPixelBufferPool)
    guard let pixelBufferPool = cvPixelBufferPool else {
      assertionFailure("Allocation failure: Could not allocate pixel buffer pool.")
      return (nil, nil, nil)
    }
    
    preallocateBuffers(pool: pixelBufferPool, allocationThreshold: outputRetainedBufferCountHint)
    
    // Get the output format description.
    var pixelBuffer: CVPixelBuffer?
    var outputFormatDescription: CMFormatDescription?
    let auxAttributes = [kCVPixelBufferPoolAllocationThresholdKey as String: outputRetainedBufferCountHint] as NSDictionary
    CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pixelBufferPool, auxAttributes, &pixelBuffer)
    if let pixelBuffer = pixelBuffer {
      CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                   imageBuffer: pixelBuffer,
                                                   formatDescriptionOut: &outputFormatDescription)
    }
    pixelBuffer = nil
    
    return (pixelBufferPool, cgColorSpace, outputFormatDescription)
  }

/// - Tag: AllocateRenderBuffers
private func preallocateBuffers(pool: CVPixelBufferPool, allocationThreshold: Int) {
  var pixelBuffers = [CVPixelBuffer]()
  var error: CVReturn = kCVReturnSuccess
  let auxAttributes = [kCVPixelBufferPoolAllocationThresholdKey as String: allocationThreshold] as NSDictionary
  var pixelBuffer: CVPixelBuffer?
  while error == kCVReturnSuccess {
    error = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool, auxAttributes, &pixelBuffer)
    if let pixelBuffer = pixelBuffer {
      pixelBuffers.append(pixelBuffer)
    }
    pixelBuffer = nil
  }
  pixelBuffers.removeAll()
}



public extension UIImage {

    func fixOrientationCGimage() -> CGImage? {

        guard let cgImage = cgImage else { return nil }
//      return cgImage

        if imageOrientation == .up { return cgImage }

        var transform = CGAffineTransform.identity

        switch imageOrientation {

        case .down, .downMirrored:
          transform = transform.translatedBy(x: size.width, y: size.height)
          transform = transform.rotated(by: CGFloat.pi)

        case .left, .leftMirrored:
          transform = transform.translatedBy(x: size.width, y: 0)
          transform = transform.rotated(by: -CGFloat.pi/2)

        case .right, .rightMirrored:
            transform = transform.translatedBy(x: 0, y: size.height)
          transform = transform.rotated(by: CGFloat.pi/2)

        case .up, .upMirrored:
            break
        default:
          break
        }

        switch imageOrientation {

        case .upMirrored, .downMirrored:
          transform = transform.translatedBy(x: size.width, y: 0)
          transform = transform.scaledBy(x: -1, y: 1)

        case .leftMirrored, .rightMirrored:
          transform = transform.translatedBy(x: size.height, y: 0)
          transform = transform.scaledBy(x: -1, y: 1)

        default:
            break
        }

        if let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: cgImage.bitsPerComponent, bytesPerRow: 0, space: cgImage.colorSpace!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {

            ctx.concatenate(transform)

            switch imageOrientation {

            case .left, .leftMirrored, .right, .rightMirrored:
                ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: size.height, height: size.width))

            default:
                ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
            }

            if let finalImage = ctx.makeImage() {
                return finalImage
            }
        }

        return nil
    }
}
