import UIKit
import Flutter
import AVFoundation
import CoreVideo

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
