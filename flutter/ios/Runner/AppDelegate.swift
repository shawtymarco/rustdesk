import UIKit
import Flutter
import AVFoundation
import CoreVideo
import VideoToolbox

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    do {
      // Mix remote audio with other apps while still respecting silent mode.
      try AVAudioSession.sharedInstance().setCategory(.ambient)
    } catch {
      NSLog("Failed to configure audio mixing: %@", error.localizedDescription)
    }
    dummyMethodToEnforceBundling();
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // With the UIScene life cycle, the FlutterViewController only exists once the scene
  // connects, and FlutterAppDelegate reaches its engine through `window`. A launch URL
  // also arrives with the scene instead of in launchOptions, so forward it to plugins here.
  func sceneWillConnect(window: UIWindow?, launchURL: URL?) {
    self.window = window
    GeneratedPluginRegistrant.register(with: self)
    registerVideoTextureChannel()
    var launchOptions: [UIApplication.LaunchOptionsKey: Any] = [:]
    if let launchURL = launchURL {
      launchOptions[.url] = launchURL
    }
    _ = super.application(UIApplication.shared, didFinishLaunchingWithOptions: launchOptions)
  }
    
  private func registerVideoTextureChannel() {
    guard let registrar = self.registrar(forPlugin: "RustDeskVideoTexture") else { return }
    let textures = registrar.textures()
    rustdesk_ios_set_video_callback(rustdeskIosOnRgba)
    rustdesk_ios_set_decoder_callback(rustdeskIosOnEncoded)
    let channel = FlutterMethodChannel(
      name: "rustdesk/video_texture", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "create":
        result(RustDeskVideoTexture.create(registry: textures))
      case "release":
        RustDeskVideoTexture.release()
        result(true)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  public func dummyMethodToEnforceBundling() {
      dummy_method_to_enforce_bundling();
    session_get_rgba(nil, 0);
  }
}

// Native video output of the controlling client: Rust hands each decoded
// BGRA frame to `rustdeskIosOnRgba`, which copies it into a CVPixelBuffer
// that Flutter shows through a `Texture` widget (see VideoTexturePaint).
final class RustDeskVideoTexture: NSObject, FlutterTexture {
  private static let sharedLock = NSLock()
  private static var shared: RustDeskVideoTexture?

  private let registry: FlutterTextureRegistry
  private(set) var textureId: Int64 = -1
  private let lock = NSLock()
  private var latest: CVPixelBuffer?
  private var pool: CVPixelBufferPool?
  private var poolWidth = 0
  private var poolHeight = 0
  private var sentFirstFrame = false
  // VideoToolbox decoder for H264/H265; used only from the Rust video thread.
  private lazy var decoder = RustDeskHwDecoder { [weak self] buffer in self?.show(buffer) }

  private init(registry: FlutterTextureRegistry) {
    self.registry = registry
    super.init()
  }

  static func create(registry: FlutterTextureRegistry) -> Int64 {
    release()
    let texture = RustDeskVideoTexture(registry: registry)
    texture.textureId = registry.register(texture)
    sharedLock.lock()
    shared = texture
    sharedLock.unlock()
    return texture.textureId
  }

  static func release() {
    sharedLock.lock()
    let old = shared
    shared = nil
    sharedLock.unlock()
    if let old = old, old.textureId >= 0 {
      old.registry.unregisterTexture(old.textureId)
    }
  }

  static func current() -> RustDeskVideoTexture? {
    sharedLock.lock()
    defer { sharedLock.unlock() }
    return shared
  }

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    lock.lock()
    defer { lock.unlock() }
    guard let buffer = latest else { return nil }
    return Unmanaged.passRetained(buffer)
  }

  private func makeBuffer(width: Int, height: Int) -> CVPixelBuffer? {
    if pool == nil || poolWidth != width || poolHeight != height {
      let attrs: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
        kCVPixelBufferMetalCompatibilityKey as String: true,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
      ]
      var newPool: CVPixelBufferPool?
      CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &newPool)
      pool = newPool
      poolWidth = width
      poolHeight = height
    }
    guard let pool = pool else { return nil }
    var buffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
    return buffer
  }

  private func show(_ buffer: CVPixelBuffer) {
    lock.lock()
    latest = buffer
    lock.unlock()
    registry.textureFrameAvailable(textureId)
  }

  /// See `rustdeskIosOnEncoded`. Returns the result code and picture size.
  func decode(
    _ data: UnsafePointer<UInt8>, len: Int, h265: Bool, key: Bool
  ) -> (Int32, Int32, Int32) {
    let res = decoder.decode(data, len: len, h265: h265, key: key)
    return (res, decoder.width, decoder.height)
  }

  /// 0: not drawn, 1: drawn, 2: drawn and first frame of this texture.
  func push(_ src: UnsafePointer<UInt8>, len: Int, width: Int, height: Int) -> Int32 {
    guard width > 0, height > 0, len >= width * height * 4 else { return 0 }
    let srcStride = len / height
    guard let buffer = makeBuffer(width: width, height: height) else { return 0 }
    CVPixelBufferLockBaseAddress(buffer, [])
    if let dst = CVPixelBufferGetBaseAddress(buffer) {
      let dstStride = CVPixelBufferGetBytesPerRow(buffer)
      let rowBytes = min(width * 4, dstStride)
      for y in 0..<height {
        memcpy(dst.advanced(by: y * dstStride), src.advanced(by: y * srcStride), rowBytes)
      }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    lock.lock()
    latest = buffer
    let first = !sentFirstFrame
    sentFirstFrame = true
    lock.unlock()
    registry.textureFrameAvailable(textureId)
    return first ? 2 : 1
  }
}

// Registered with Rust once at start-up; Rust calls it for every frame.
let rustdeskIosOnRgba: rustdesk_ios_on_rgba_fn = { buffer, len, width, height in
  guard let buffer = buffer, let texture = RustDeskVideoTexture.current() else { return 0 }
  return texture.push(buffer, len: Int(len), width: Int(width), height: Int(height))
}

// Registered with Rust once at start-up; Rust calls it for every H264/H265
// frame. 0: not handled (no texture), 1: handled, 2: needs a key frame first.
let rustdeskIosOnEncoded: rustdesk_ios_on_encoded_fn = {
  data, len, h265, key, outWidth, outHeight in
  guard let data = data, let texture = RustDeskVideoTexture.current() else { return 0 }
  let (res, width, height) = texture.decode(
    data, len: Int(len), h265: h265 != 0, key: key != 0)
  outWidth?.pointee = width
  outHeight?.pointee = height
  return res
}

/// Hardware H264/H265 decoding with VideoToolbox. Input is the Annex-B stream
/// the peer sends; parameter sets build the format description, other NAL
/// units are repacked with 4-byte lengths. Pictures come out as BGRA
/// CVPixelBuffers the Flutter texture shows directly.
final class RustDeskHwDecoder {
  private var session: VTDecompressionSession?
  private var format: CMVideoFormatDescription?
  private var h265 = false
  private var vps: [UInt8]?
  private var sps: [UInt8]?
  private var pps: [UInt8]?
  private var waitingKey = true
  private(set) var width: Int32 = 0
  private(set) var height: Int32 = 0
  private let onImage: (CVPixelBuffer) -> Void

  init(onImage: @escaping (CVPixelBuffer) -> Void) {
    self.onImage = onImage
  }

  deinit {
    invalidate()
  }

  private func invalidate() {
    if let session = session {
      VTDecompressionSessionInvalidate(session)
    }
    session = nil
  }

  /// 1: decoded (or nothing to decode), 2: waiting for a key frame.
  func decode(_ data: UnsafePointer<UInt8>, len: Int, h265: Bool, key: Bool) -> Int32 {
    if h265 != self.h265 {
      invalidate()
      format = nil
      vps = nil
      sps = nil
      pps = nil
      self.h265 = h265
      waitingKey = true
    }
    var paramsChanged = false
    var payload = [UInt8]()
    payload.reserveCapacity(len + 16)
    for nal in RustDeskHwDecoder.splitAnnexB(data, len) {
      if nal.isEmpty { continue }
      if h265 {
        switch (nal[0] >> 1) & 0x3F {
        case 32:
          paramsChanged = RustDeskHwDecoder.store(&vps, nal) || paramsChanged
          continue
        case 33:
          paramsChanged = RustDeskHwDecoder.store(&sps, nal) || paramsChanged
          continue
        case 34:
          paramsChanged = RustDeskHwDecoder.store(&pps, nal) || paramsChanged
          continue
        case 35:
          continue  // access unit delimiter
        default:
          break
        }
      } else {
        switch nal[0] & 0x1F {
        case 7:
          paramsChanged = RustDeskHwDecoder.store(&sps, nal) || paramsChanged
          continue
        case 8:
          paramsChanged = RustDeskHwDecoder.store(&pps, nal) || paramsChanged
          continue
        case 9:
          continue  // access unit delimiter
        default:
          break
        }
      }
      let length = UInt32(nal.count).bigEndian
      withUnsafeBytes(of: length) { payload.append(contentsOf: $0) }
      payload.append(contentsOf: nal)
    }
    if paramsChanged || format == nil {
      if !rebuildFormat() {
        waitingKey = true
        return 2
      }
    }
    if waitingKey {
      if !key { return 2 }
      waitingKey = false
    }
    if payload.isEmpty { return 1 }
    guard let session = session, let format = format,
      let sample = RustDeskHwDecoder.makeSample(payload, format: format)
    else {
      waitingKey = true
      return 2
    }
    var infoFlags = VTDecodeInfoFlags()
    let status = VTDecompressionSessionDecodeFrame(
      session, sampleBuffer: sample, flags: [], infoFlagsOut: &infoFlags
    ) { [weak self] status, _, imageBuffer, _, _ in
      guard status == noErr, let imageBuffer = imageBuffer else { return }
      self?.onImage(imageBuffer)
    }
    if status != noErr {
      // For example kVTInvalidSessionErr after the app was in the background.
      if status == kVTInvalidSessionErr {
        invalidate()
        _ = createSession()
      }
      waitingKey = true
      return 2
    }
    return 1
  }

  private static func store(_ slot: inout [UInt8]?, _ nal: UnsafeBufferPointer<UInt8>) -> Bool {
    let bytes = Array(nal)
    if slot == bytes { return false }
    slot = bytes
    return true
  }

  private func rebuildFormat() -> Bool {
    var newFormat: CMVideoFormatDescription?
    var status: OSStatus = -1
    if h265 {
      guard let vps = vps, let sps = sps, let pps = pps else { return false }
      vps.withUnsafeBufferPointer { v in
        sps.withUnsafeBufferPointer { s in
          pps.withUnsafeBufferPointer { p in
            let pointers: [UnsafePointer<UInt8>] = [v.baseAddress!, s.baseAddress!, p.baseAddress!]
            let sizes = [vps.count, sps.count, pps.count]
            status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
              allocator: kCFAllocatorDefault, parameterSetCount: 3,
              parameterSetPointers: pointers, parameterSetSizes: sizes,
              nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &newFormat)
          }
        }
      }
    } else {
      guard let sps = sps, let pps = pps else { return false }
      sps.withUnsafeBufferPointer { s in
        pps.withUnsafeBufferPointer { p in
          let pointers: [UnsafePointer<UInt8>] = [s.baseAddress!, p.baseAddress!]
          let sizes = [sps.count, pps.count]
          status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
            allocator: kCFAllocatorDefault, parameterSetCount: 2,
            parameterSetPointers: pointers, parameterSetSizes: sizes,
            nalUnitHeaderLength: 4, formatDescriptionOut: &newFormat)
        }
      }
    }
    guard status == noErr, let newFormat = newFormat else { return false }
    format = newFormat
    let dimensions = CMVideoFormatDescriptionGetDimensions(newFormat)
    width = dimensions.width
    height = dimensions.height
    if let session = session,
      VTDecompressionSessionCanAcceptFormatDescription(session, formatDescription: newFormat)
    {
      return true
    }
    invalidate()
    return createSession()
  }

  private func createSession() -> Bool {
    guard let format = format else { return false }
    let attributes: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
      kCVPixelBufferMetalCompatibilityKey as String: true,
    ]
    var newSession: VTDecompressionSession?
    let status = VTDecompressionSessionCreate(
      allocator: kCFAllocatorDefault, formatDescription: format, decoderSpecification: nil,
      imageBufferAttributes: attributes as CFDictionary, outputCallback: nil,
      decompressionSessionOut: &newSession)
    guard status == noErr, let newSession = newSession else {
      NSLog("VTDecompressionSessionCreate failed: %d", status)
      return false
    }
    VTSessionSetProperty(
      newSession, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
    session = newSession
    return true
  }

  private static func makeSample(_ payload: [UInt8], format: CMVideoFormatDescription)
    -> CMSampleBuffer?
  {
    var block: CMBlockBuffer?
    var status = CMBlockBufferCreateWithMemoryBlock(
      allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: payload.count,
      blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
      dataLength: payload.count, flags: 0, blockBufferOut: &block)
    guard status == kCMBlockBufferNoErr, let block = block else { return nil }
    status = payload.withUnsafeBytes {
      CMBlockBufferReplaceDataBytes(
        with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0,
        dataLength: payload.count)
    }
    guard status == kCMBlockBufferNoErr else { return nil }
    var sample: CMSampleBuffer?
    var sampleSize = payload.count
    status = CMSampleBufferCreateReady(
      allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
      sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
      sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sample)
    guard status == noErr else { return nil }
    return sample
  }

  /// NAL units of an Annex-B buffer, without start codes.
  private static func splitAnnexB(_ data: UnsafePointer<UInt8>, _ len: Int)
    -> [UnsafeBufferPointer<UInt8>]
  {
    var nals: [UnsafeBufferPointer<UInt8>] = []
    var start = -1
    var i = 0
    while i + 3 <= len {
      if data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1 {
        if start >= 0 {
          var end = i
          while end > start && data[end - 1] == 0 { end -= 1 }
          nals.append(UnsafeBufferPointer(start: data + start, count: end - start))
        }
        i += 3
        start = i
      } else {
        i += 1
      }
    }
    if start >= 0 {
      if start < len {
        nals.append(UnsafeBufferPointer(start: data + start, count: len - start))
      }
    } else if len > 0 {
      // No start code: treat the buffer as a single NAL unit.
      nals.append(UnsafeBufferPointer(start: data, count: len))
    }
    return nals
  }
}
