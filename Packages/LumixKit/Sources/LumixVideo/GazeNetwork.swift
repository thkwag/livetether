import CryptoKit
import Foundation
import Metal
import MetalPerformanceShadersGraph

/// Where each weight of the gaze-warping network sits in the published checkpoint files.
public struct GazeWeightManifest: Decodable, Sendable {
    public struct File: Decodable, Sendable {
        public struct Tensor: Decodable, Sendable {
            public let offset: Int
            public let shape: [Int]
        }
        /// The file's path below `source`.
        public let path: String
        public let size: Int
        public let sha256: String
        public let tensors: [String: Tensor]
    }

    /// The folder the files are downloaded from, at a fixed commit of the original repository.
    public let source: String
    public let commit: String
    /// Keyed by the network: "L" works on the eye on the picture's right, "R" on the left.
    public let files: [String: File]

    /// The manifest that ships with this module.
    public static func bundled() throws -> GazeWeightManifest {
        guard let url = Bundle.module.url(forResource: "gaze-weights", withExtension: "json") else {
            throw GazeModelError.manifestMissing
        }
        return try JSONDecoder().decode(GazeWeightManifest.self, from: Data(contentsOf: url))
    }

    /// The URL to download a file from.
    public func url(of file: File) -> URL? {
        URL(string: "\(source)/\(file.path)")
    }

    /// Whether `data` is exactly the published file.
    public static func matches(_ data: Data, _ file: File) -> Bool {
        data.count == file.size && SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == file.sha256
    }
}

public enum GazeModelError: Error, Equatable, Sendable {
    case manifestMissing
    case fileMismatch(String)
    case tensorMissing(String)
    case metalUnavailable
    case runFailed(String)
}

/// The two gaze-warping networks of Hsu et al. (ACM TOMM 2019), built from the downloaded weights.
///
/// Each takes an eye patch of 48 × 64 BGR pixels from 0 to 1, twelve anchor maps and the redirection
/// angle, and returns the warp flow and the two light weights per pixel, as the original model does.
/// Layouts follow TensorFlow's: tensors are height × width × channels and kernels are
/// height × width × input × output, so the weights are used as they are stored.
public final class GazeNetwork: @unchecked Sendable {
    public static let height = 48
    public static let width = 64

    public struct Output {
        /// height × width × 2, interleaved.
        public let flow: [Float]
        public let light: [Float]
    }

    // `MPSGraph.run` is thread-safe for a graph that is not changed after it is built.
    private let graph = MPSGraph()
    private let device: MPSGraphDevice
    private let inputs: [String: (patch: MPSGraphTensor, anchors: MPSGraphTensor)]
    private let angle: MPSGraphTensor
    private let outputs: [String: (flow: MPSGraphTensor, light: MPSGraphTensor)]

    /// Builds both networks from the checkpoint files in `folder`, laid out as the manifest's paths.
    public init(folder: URL, manifest: GazeWeightManifest) throws {
        guard let metal = MTLCreateSystemDefaultDevice() else { throw GazeModelError.metalUnavailable }
        device = MPSGraphDevice(mtlDevice: metal)
        angle = graph.placeholder(shape: [1, 2], dataType: .float32, name: "angle")
        var inputs: [String: (MPSGraphTensor, MPSGraphTensor)] = [:]
        var outputs: [String: (MPSGraphTensor, MPSGraphTensor)] = [:]
        for side in ["L", "R"] {
            guard let file = manifest.files[side] else { throw GazeModelError.fileMismatch(side) }
            let data = try Data(contentsOf: folder.appendingPathComponent(file.path))
            guard GazeWeightManifest.matches(data, file) else { throw GazeModelError.fileMismatch(file.path) }
            let weights = Weights(data: data, file: file, graph: graph)
            let patch = graph.placeholder(shape: [1, 48, 64, 3], dataType: .float32, name: "\(side)_patch")
            let anchors = graph.placeholder(shape: [1, 48, 64, 12], dataType: .float32, name: "\(side)_anchors")
            inputs[side] = (patch, anchors)
            outputs[side] = try Self.network(graph, weights, patch: patch, anchors: anchors, angle: angle)
        }
        self.inputs = inputs
        self.outputs = outputs
    }

    /// Runs the network for "L" on one eye and the network for "R" on the other.
    public func run(left: (patch: [Float], anchors: [Float]), right: (patch: [Float], anchors: [Float]), angle: (Float, Float)) throws -> (left: Output, right: Output) {
        guard let leftInputs = inputs["L"], let rightInputs = inputs["R"],
              let leftOutputs = outputs["L"], let rightOutputs = outputs["R"] else {
            throw GazeModelError.runFailed("networks missing")
        }
        func tensor(_ values: [Float], _ shape: [NSNumber]) -> MPSGraphTensorData {
            MPSGraphTensorData(device: device, data: values.withUnsafeBufferPointer { Data(buffer: $0) }, shape: shape, dataType: .float32)
        }
        let image: [NSNumber] = [1, 48, 64, 3]
        let maps: [NSNumber] = [1, 48, 64, 12]
        let feeds: [MPSGraphTensor: MPSGraphTensorData] = [
            leftInputs.patch: tensor(left.patch, image), leftInputs.anchors: tensor(left.anchors, maps),
            rightInputs.patch: tensor(right.patch, image), rightInputs.anchors: tensor(right.anchors, maps),
            self.angle: tensor([angle.0, angle.1], [1, 2]),
        ]
        let targets = [leftOutputs.flow, leftOutputs.light, rightOutputs.flow, rightOutputs.light]
        let results = graph.run(feeds: feeds, targetTensors: targets, targetOperations: nil)
        func values(_ tensor: MPSGraphTensor) throws -> [Float] {
            guard let data = results[tensor] else { throw GazeModelError.runFailed("output missing") }
            var output = [Float](repeating: 0, count: 48 * 64 * 2)
            output.withUnsafeMutableBytes { data.mpsndarray().readBytes($0.baseAddress!, strideBytes: nil) }
            return output
        }
        return (
            Output(flow: try values(leftOutputs.flow), light: try values(leftOutputs.light)),
            Output(flow: try values(rightOutputs.flow), light: try values(rightOutputs.light))
        )
    }

    // MARK: - Network

    private struct Weights {
        let data: Data
        let file: GazeWeightManifest.File
        let graph: MPSGraph

        func callAsFunction(_ name: String) throws -> MPSGraphTensor {
            guard let tensor = file.tensors[name] else { throw GazeModelError.tensorMissing(name) }
            let count = tensor.shape.reduce(1, *)
            let bytes = data.subdata(in: tensor.offset..<(tensor.offset + count * 4))
            return graph.constant(bytes, shape: tensor.shape.map { NSNumber(value: $0) }, dataType: .float32)
        }
    }

    private static func network(_ graph: MPSGraph, _ w: Weights, patch: MPSGraphTensor, anchors: MPSGraphTensor, angle: MPSGraphTensor) throws -> (MPSGraphTensor, MPSGraphTensor) {
        var encoded = angle
        for index in 0..<3 {
            let scope = "encoder/dnn_blk_\(index)/dnn"
            let product = graph.matrixMultiplication(primary: encoded, secondary: try w("\(scope)/kernel"), name: nil)
            encoded = graph.reLU(with: graph.addition(product, try w("\(scope)/bias"), name: nil), name: nil)
        }
        let angleMap = graph.broadcast(graph.reshape(encoded, shape: [1, 1, 1, 16], name: nil), shape: [1, 48, 64, 16], name: nil)
        let inputs = graph.concatTensors([patch, anchors, angleMap], dimension: 3, name: nil)

        let small = graph.avgPooling2D(withSourceTensor: inputs, descriptor: pooling(stride: 2, padding: .TF_VALID), name: nil)
        var coarse = graph.tanh(with: try transModule(graph, w, small, scope: "warping_module/coarse_level"), name: nil)
        // Nearest-neighbour doubling: every value repeated over a 2 × 2 block.
        coarse = graph.reshape(
            graph.broadcast(graph.reshape(coarse, shape: [1, 24, 1, 32, 1, 16], name: nil), shape: [1, 24, 2, 32, 2, 16], name: nil),
            shape: [1, 48, 64, 16], name: nil
        )
        // TensorFlow's SAME 2 × 2 average with stride 1 pads the bottom and right edge and leaves the
        // padding out of the average, which edge replication reproduces.
        coarse = graph.padTensor(coarse, with: .clampToEdge, leftPadding: [0, 0, 0, 0], rightPadding: [0, 1, 1, 0], constantValue: 0, name: nil)
        coarse = graph.avgPooling2D(withSourceTensor: coarse, descriptor: pooling(stride: 1, padding: .TF_VALID), name: nil)

        let fine = try transModule(graph, w, graph.concatTensors([inputs, coarse], dimension: 3, name: nil), scope: "warping_module/fine_level")
        let flow = graph.tanh(with: graph.sliceTensor(fine, dimension: 3, start: 0, length: 2, name: nil), name: nil)
        let lightInput = graph.sliceTensor(fine, dimension: 3, start: 2, length: 2, name: nil)
        let l0 = try block(graph, w, lightInput, scope: "lcm_module/cnn_blk_0")
        let l1 = try block(graph, w, l0, scope: "lcm_module/cnn_blk_1")
        let light = graph.softMax(with: try convolution(graph, w, l1, kernel: "lcm_module/cnn_2/kernel"), axis: 3, name: nil)
        return (flow, light)
    }

    private static func pooling(stride: Int, padding: MPSGraphPaddingStyle) -> MPSGraphPooling2DOpDescriptor {
        MPSGraphPooling2DOpDescriptor(
            kernelWidth: 2, kernelHeight: 2, strideInX: stride, strideInY: stride,
            paddingStyle: padding, dataLayout: .NHWC
        )!
    }

    private static func convolution(_ graph: MPSGraph, _ w: Weights, _ input: MPSGraphTensor, kernel: String) throws -> MPSGraphTensor {
        let descriptor = MPSGraphConvolution2DOpDescriptor(
            strideInX: 1, strideInY: 1, dilationRateInX: 1, dilationRateInY: 1, groups: 1,
            paddingStyle: .TF_SAME, dataLayout: .NHWC, weightsLayout: .HWIO
        )!
        return graph.convolution2D(input, weights: try w(kernel), descriptor: descriptor, name: nil)
    }

    /// Convolution, ReLU, then batch normalization with the stored statistics.
    private static func block(_ graph: MPSGraph, _ w: Weights, _ input: MPSGraphTensor, scope: String) throws -> MPSGraphTensor {
        let activated = graph.reLU(with: try convolution(graph, w, input, kernel: "\(scope)/cnn/kernel"), name: nil)
        return graph.normalize(
            activated,
            mean: try w("\(scope)/bn_layer/moving_mean"),
            variance: try w("\(scope)/bn_layer/moving_variance"),
            gamma: try w("\(scope)/bn_layer/gamma"),
            beta: try w("\(scope)/bn_layer/beta"),
            epsilon: 1e-5,
            name: nil
        )
    }

    private static func transModule(_ graph: MPSGraph, _ w: Weights, _ input: MPSGraphTensor, scope: String) throws -> MPSGraphTensor {
        let b0 = try block(graph, w, input, scope: "\(scope)/cnn_blk_0")
        let b1 = try block(graph, w, b0, scope: "\(scope)/cnn_blk_1")
        let b2 = try block(graph, w, graph.concatTensors([b0, b1], dimension: 3, name: nil), scope: "\(scope)/cnn_blk_2")
        let b3 = try block(graph, w, graph.concatTensors([b0, b1, b2], dimension: 3, name: nil), scope: "\(scope)/cnn_blk_3")
        return try convolution(graph, w, b3, kernel: "\(scope)/cnn_4/kernel")
    }
}
