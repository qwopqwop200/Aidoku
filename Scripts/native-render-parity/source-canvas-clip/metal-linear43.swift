import Foundation
import Metal
struct Frame { var origin: SIMD2<Int32>; var size: SIMD2<Int32> }
@main struct Probe {
    static func main() throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let doc = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("web-dom-and-saved-masks.json"))) as! [String: Any]
        let device = MTLCreateSystemDefaultDevice()!, queue = device.makeCommandQueue()!
        let source = #"""
        #include <metal_stdlib>
        using namespace metal;
        struct Frame { int2 origin; int2 size; };
        kernel void floatLinear(texture2d<float,access::sample> src [[texture(0)]],
                                texture2d<float,access::write> dst [[texture(1)]],
                                constant Frame &frame [[buffer(0)]],uint2 p [[thread_position_in_grid]]) {
            if(p.x>=dst.get_width()||p.y>=dst.get_height())return;
            int2 relative=int2(p)-frame.origin;
            if(any(relative<0)||any(relative>=frame.size))return;
            constexpr sampler linear(coord::normalized,address::clamp_to_edge,filter::linear);
            dst.write(src.sample(linear,(float2(relative)+0.5f)/float2(frame.size)),p);
        }
        kernel void halfLinear(texture2d<half,access::sample> src [[texture(0)]],
                               texture2d<half,access::write> dst [[texture(1)]],
                               constant Frame &frame [[buffer(0)]],uint2 p [[thread_position_in_grid]]) {
            if(p.x>=dst.get_width()||p.y>=dst.get_height())return;
            int2 relative=int2(p)-frame.origin;
            if(any(relative<0)||any(relative>=frame.size))return;
            constexpr sampler linear(coord::normalized,address::clamp_to_edge,filter::linear);
            dst.write(src.sample(linear,(float2(relative)+0.5f)/float2(frame.size)),p);
        }
        """#
        let library = try device.makeLibrary(source: source, options: nil)
        for function in ["floatLinear", "halfLinear"] {
            let pipeline = try device.makeComputePipelineState(function: library.makeFunction(name: function)!)
            let description = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1920, height: 3000, mipmapped: false)
            description.storageMode = .shared; description.usage = [.shaderRead, .shaderWrite]
            let destination = device.makeTexture(descriptor: description)!
            let white = Data(repeating: 255, count: 1920 * 3000 * 4)
            white.withUnsafeBytes { destination.replace(region: MTLRegionMake2D(0, 0, 1920, 3000), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 1920 * 4) }
            for record in doc["records"] as! [[String: Any]] {
                let id = record["id"] as! String, used = record["used"] as! [Double]
                let left = floor(used[0] + 0.5), top = floor(used[1] + 0.5)
                let right = floor(used[0] + used[2] + 0.5), bottom = floor(used[1] + used[3] + 0.5)
                guard right > left, bottom > top else { continue }
                let pixels = try Data(contentsOf: directory.appendingPathComponent("source-\(id).rgba"))
                let inputDescription = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 20, height: 20, mipmapped: false)
                inputDescription.storageMode = .shared; inputDescription.usage = .shaderRead
                let input = device.makeTexture(descriptor: inputDescription)!
                pixels.withUnsafeBytes { input.replace(region: MTLRegionMake2D(0, 0, 20, 20), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 80) }
                var frame = Frame(origin: SIMD2(Int32(left * 3), Int32(top * 3)), size: SIMD2(Int32((right-left)*3), Int32((bottom-top)*3)))
                let command = queue.makeCommandBuffer()!, encoder = command.makeComputeCommandEncoder()!
                encoder.setComputePipelineState(pipeline); encoder.setTexture(input, index: 0); encoder.setTexture(destination, index: 1)
                encoder.setBytes(&frame, length: MemoryLayout<Frame>.stride, index: 0)
                encoder.dispatchThreads(MTLSize(width: 1920, height: 3000, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
                encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
                if let error = command.error { throw error }
            }
            var bytes = Data(repeating: 0, count: 1920 * 3000 * 4)
            bytes.withUnsafeMutableBytes { destination.getBytes($0.baseAddress!, bytesPerRow: 1920 * 4, from: MTLRegionMake2D(0, 0, 1920, 3000), mipmapLevel: 0) }
            try bytes.write(to: output.appendingPathComponent(function + ".rgba"))
            if function == "floatLinear" {
                let smallerDescription = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 960, height: 1500, mipmapped: false)
                smallerDescription.storageMode = .shared; smallerDescription.usage = [.shaderRead, .shaderWrite]
                let smaller = device.makeTexture(descriptor: smallerDescription)!
                var frame = Frame(origin: SIMD2(0, 0), size: SIMD2(960, 1500))
                let command = queue.makeCommandBuffer()!, encoder = command.makeComputeCommandEncoder()!
                encoder.setComputePipelineState(pipeline); encoder.setTexture(destination, index: 0); encoder.setTexture(smaller, index: 1)
                encoder.setBytes(&frame, length: MemoryLayout<Frame>.stride, index: 0)
                encoder.dispatchThreads(MTLSize(width: 960, height: 1500, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
                encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
                if let error = command.error { throw error }
                var reduced = Data(repeating: 0, count: 960 * 1500 * 4)
                reduced.withUnsafeMutableBytes { smaller.getBytes($0.baseAddress!, bytesPerRow: 960 * 4, from: MTLRegionMake2D(0, 0, 960, 1500), mipmapLevel: 0) }
                try reduced.write(to: output.appendingPathComponent("floatLinear-halfscale.rgba"))
            }
        }
        print(device.name)
    }
}
