import CoreImage
import CoreVideo
import Foundation
import Testing
@testable import Nanight

struct BabyPresenceTests {
    @Test func bundledModelProducesFiniteScores() async throws {
        var buffer: CVPixelBuffer?
        #expect(CVPixelBufferCreate(kCFAllocatorDefault, 256, 256, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess)
        let frame = try #require(buffer)
        CIContext().render(CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 256, height: 256)), to: frame)
        let result = try await NanightCribClassifier.shared.classify(NanightPresenceFrame(buffer: frame))
        #expect(result.babySimilarity.isFinite)
        #expect(result.emptySimilarity.isFinite)
        #expect(!result.detected)
    }
}
