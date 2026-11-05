#if os(iOS)
import CoreImage
public struct FinderFrame: @unchecked Sendable {
    public let image: CIImage          // pixel buffer as delivered (sensor orientation)
    public let rotationAngle: Double   // degrees, from the rotation coordinator (preview)
    public let exposureTime: Double?   // seconds
    public let timestamp: Double       // seconds, host time
    public let index: Int              // monotonically increasing
    public init(image: CIImage, rotationAngle: Double, exposureTime: Double?, timestamp: Double, index: Int) {
        self.image = image; self.rotationAngle = rotationAngle; self.exposureTime = exposureTime
        self.timestamp = timestamp; self.index = index
    }
}
public protocol FrameSource: AnyObject, Sendable {
    func setHandler(_ handler: @escaping @Sendable (FinderFrame) -> Void)
    func start()
    func stop()
}
#endif
