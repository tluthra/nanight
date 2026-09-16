import CoreImage
import CoreML
import CoreVideo
import Foundation

/// One retained decoded frame, read only while inference runs on its own actor.
nonisolated struct NanightPresenceFrame: @unchecked Sendable {
    let buffer: CVPixelBuffer
}

nonisolated struct NanightCribClassification: Sendable {
    let babySimilarity: Float
    let emptySimilarity: Float
    let milliseconds: Double
    var margin: Float { babySimilarity - emptySimilarity }
    // This is a cosine-similarity margin, not a calibrated probability.
    var detected: Bool { babySimilarity >= 0.2 && margin >= 0.015 }
}

/// Cached Core ML model. No images or image embeddings are saved or uploaded.
actor NanightCribClassifier {
    static let shared = NanightCribClassifier()
    private let modelURL: URL?
    private let promptsURL: URL?
    private var model: MLModel?
    private var babyEmbedding: [Float] = []
    private var emptyEmbedding: [Float] = []
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    init(modelURL: URL? = Bundle.main.url(forResource: "mobileclip_s2_image", withExtension: "mlmodelc"),
         promptsURL: URL? = Bundle.main.url(forResource: "CribPrompts", withExtension: "json")) {
        self.modelURL = modelURL
        self.promptsURL = promptsURL
    }

    private struct Prompts: Decodable {
        let embeddings: [String: [Float]]
    }

    enum Failure: Error { case missingResources, invalidEmbedding, pixelBuffer }

    func classify(_ frame: NanightPresenceFrame) throws -> NanightCribClassification {
        let started = ProcessInfo.processInfo.systemUptime
        if model == nil {
            guard let modelURL, let promptsURL else { throw Failure.missingResources }
            let prompts = try JSONDecoder().decode(Prompts.self, from: Data(contentsOf: promptsURL))
            guard let baby = prompts.embeddings["baby"], let empty = prompts.embeddings["empty"],
                  baby.count == 512, empty.count == 512,
                  baby.allSatisfy(\.isFinite), empty.allSatisfy(\.isFinite) else { throw Failure.invalidEmbedding }
            babyEmbedding = baby
            emptyEmbedding = empty
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .all
            model = try MLModel(contentsOf: modelURL, configuration: configuration)
        }
        guard let model else { throw Failure.missingResources }
        let image = CIImage(cvPixelBuffer: frame.buffer)
        let width = image.extent.width, height = image.extent.height
        let side = min(width, height)
        // Whole frame plus overlapping crops preserve a baby near any edge.
        var regions = [image.extent,
                       CGRect(x: 0, y: 0, width: side, height: side),
                       CGRect(x: width - side, y: height - side, width: side, height: side)]
        for x in [0.0, 0.4] {
            for y in [0.0, 0.35] {
                regions.append(CGRect(x: floor(x * width), y: floor(y * height),
                                      width: floor((x + 0.6) * width) - floor(x * width),
                                      height: floor((y + 0.65) * height) - floor(y * height)))
            }
        }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, 256, 256, kCVPixelFormatType_32BGRA,
                                  [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer else { throw Failure.pixelBuffer }
        var bestBaby: Float = 0, bestEmpty: Float = 1
        for region in regions {
            let scores: (Float, Float) = try autoreleasepool {
                let crop = image.cropped(to: region)
                    .transformed(by: CGAffineTransform(translationX: -region.minX, y: -region.minY))
                    .transformed(by: CGAffineTransform(scaleX: 256 / region.width, y: 256 / region.height))
                context.render(crop, to: buffer, bounds: CGRect(x: 0, y: 0, width: 256, height: 256), colorSpace: colorSpace)
                let input = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: buffer)])
                let output = try model.prediction(from: input)
                guard let vector = output.featureValue(for: "final_emb_1")?.multiArrayValue,
                      vector.count == babyEmbedding.count else { throw Failure.invalidEmbedding }
                let values = (0..<vector.count).map { vector[$0].floatValue }
                let norm = sqrt(values.reduce(Float(0)) { $0 + $1 * $1 })
                guard norm.isFinite, norm > 0 else { throw Failure.invalidEmbedding }
                let baby = zip(values, babyEmbedding).reduce(Float(0)) { $0 + $1.0 * $1.1 } / norm
                let empty = zip(values, emptyEmbedding).reduce(Float(0)) { $0 + $1.0 * $1.1 } / norm
                return (baby, empty)
            }
            if scores.0 - scores.1 > bestBaby - bestEmpty {
                bestBaby = scores.0
                bestEmpty = scores.1
            }
        }
        return NanightCribClassification(babySimilarity: bestBaby, emptySimilarity: bestEmpty,
                                        milliseconds: (ProcessInfo.processInfo.systemUptime - started) * 1_000)
    }
}
