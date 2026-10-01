import Compression
import Foundation
import Testing
@testable import Aidoku

private final class NativeKernelFixtureBundle: NSObject {}

@Suite(.serialized)
struct NativeTranslationPixelKernelBridgeTests {
    private enum FixtureError: Error { case missingResource, invalidResource, invalidArgument, invalidPointer, wrongElementType, missingKernel }
    private struct Manifest: Decodable {
        let version: Int
        let frozenWASMSHA256: String
        let cases: [Fixture]
    }
    private struct Fixture: Decodable {
        let id: String
        let name: String
        let data: Data
        let expectedData: Data
        let expectedReturns: [Int?]
        let buffers: [String: BufferDescriptor]
        let calls: [Call]
    }
    private struct BufferDescriptor: Decodable {
        let offset: Int
        let kind: String
        let count: Int
        var byteCount: Int { count * (kind == "u8" ? 1 : kind == "f64" ? 8 : 4) }
    }
    private struct Call: Decodable { let name: String; let args: [Argument] }
    private enum Argument: Decodable {
        case pointer(Int), number(Double)
        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let values = try? container.decode([String: Int].self), let pointer = values["pointer"] { self = .pointer(pointer) }
            else { self = .number(try container.decode(Double.self)) }
        }
        func offset() throws -> Int {
            guard case .pointer(let value) = self else { throw FixtureError.invalidArgument }
            return value
        }
        func integer() throws -> Int32 {
            guard case .number(let value) = self, value.isFinite, floor(value) == value,
                  value >= Double(Int32.min), value <= Double(Int32.max) else { throw FixtureError.invalidArgument }
            return Int32(value)
        }
        func double() throws -> Double {
            guard case .number(let value) = self, value.isFinite else { throw FixtureError.invalidArgument }
            return value
        }
    }
    private enum Storage {
        case bytes(NativeKernelBuffer<UInt8>), integers(NativeKernelBuffer<Int32>)
        case floats(NativeKernelBuffer<Float>), doubles(NativeKernelBuffer<Double>)
        init(descriptor: BufferDescriptor, arena: NativeKernelBuffer<UInt8>) throws {
            let offset = descriptor.offset, count = descriptor.count
            switch descriptor.kind {
            case "u8": self = .bytes(try arena.view(as: UInt8.self, byteOffset: offset, count: count))
            case "i32": self = .integers(try arena.view(as: Int32.self, byteOffset: offset, count: count))
            case "f32": self = .floats(try arena.view(as: Float.self, byteOffset: offset, count: count))
            case "f64": self = .doubles(try arena.view(as: Double.self, byteOffset: offset, count: count))
            default: throw FixtureError.wrongElementType
            }
        }
        var data: Data {
            switch self {
            case .bytes(let value): value.values.withUnsafeBytes { Data($0) }
            case .integers(let value): value.values.withUnsafeBytes { Data($0) }
            case .floats(let value): value.values.withUnsafeBytes { Data($0) }
            case .doubles(let value): value.values.withUnsafeBytes { Data($0) }
            }
        }
        func view<Element: NativeKernelElement>(as element: Element.Type, byteOffset: Int, count: Int) throws -> NativeKernelBuffer<Element> {
            switch self {
            case .bytes(let value): try value.view(as: element, byteOffset: byteOffset, count: count)
            case .integers(let value): try value.view(as: element, byteOffset: byteOffset, count: count)
            case .floats(let value): try value.view(as: element, byteOffset: byteOffset, count: count)
            case .doubles(let value): try value.view(as: element, byteOffset: byteOffset, count: count)
            }
        }
    }
    private final class Buffers {
        let arena: NativeKernelBuffer<UInt8>
        let descriptors: [String: BufferDescriptor]
        let storage: [String: Storage]
        init(_ fixture: Fixture) throws {
            let arena = try NativeKernelBuffer<UInt8>(values: Array(fixture.data))
            self.arena = arena
            descriptors = fixture.buffers
            storage = try fixture.buffers.mapValues { try Storage(descriptor: $0, arena: arena) }
        }
        func buffer<Element: NativeKernelElement>(_ argument: Argument, as element: Element.Type) throws -> NativeKernelBuffer<Element> {
            let pointer = try argument.offset()
            guard let (name, descriptor) = descriptors.first(where: { pointer >= $0.value.offset && pointer < $0.value.offset + $0.value.byteCount }),
                  let storage = storage[name] else { throw FixtureError.invalidPointer }
            let offset = pointer - descriptor.offset
            return try storage.view(as: element, byteOffset: offset, count: (descriptor.byteCount - offset) / MemoryLayout<Element>.stride)
        }
        func u8(_ argument: Argument) throws -> NativeKernelBuffer<UInt8> { try buffer(argument, as: UInt8.self) }
        func i32(_ argument: Argument) throws -> NativeKernelBuffer<Int32> { try buffer(argument, as: Int32.self) }
        func f32(_ argument: Argument) throws -> NativeKernelBuffer<Float> { try buffer(argument, as: Float.self) }
        func f64(_ argument: Argument) throws -> NativeKernelBuffer<Double> { try buffer(argument, as: Double.self) }
    }

    private static func manifest() throws -> Manifest {
        let bundle = Bundle(for: NativeKernelFixtureBundle.self)
        let filename = "native-kernel-bridge-fixtures.json.deflate"
        let direct = bundle.url(forResource: "native-kernel-bridge-fixtures.json", withExtension: "deflate")
        let nested = bundle.resourceURL.flatMap { root in
            FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL }.first { $0.lastPathComponent == filename }
        }
        guard let url = direct ?? nested else { throw FixtureError.missingResource }
        let compressed = try Data(contentsOf: url)
        guard compressed.count > 8 else { throw FixtureError.invalidResource }
        let length = compressed.prefix(8).enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << ($1.offset * 8) }
        guard length > 0, length < 64 * 1_024 * 1_024 else { throw FixtureError.invalidResource }
        let decodedCount = Int(length)
        var decoded = [UInt8](repeating: 0, count: decodedCount)
        let count = decoded.withUnsafeMutableBytes { destination in
            compressed.withUnsafeBytes { source in
                compression_decode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!, decodedCount,
                    source.bindMemory(to: UInt8.self).baseAddress!.advanced(by: 8), compressed.count - 8, nil, COMPRESSION_ZLIB)
            }
        }
        guard count == decoded.count else { throw FixtureError.invalidResource }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(decoded))
        guard manifest.version == 1, manifest.cases.count == 83,
              manifest.frozenWASMSHA256 == "11efad914d1d7b1c3b8740803bdfa6854d6b934c158c0e694f9cafb037ace762" else { throw FixtureError.invalidResource }
        return manifest
    }

    private func execute(_ call: Call, buffers: Buffers) throws -> Int? {
        let args = call.args
        switch call.name {
        case "lettering_rays":
            return Int(try NativeTranslationPixelKernels.lettering_rays(
                rgba: buffers.u8(args[0]),
                dark: buffers.u8(args[1]),
                w: args[2].integer(),
                h: args[3].integer(),
                x0: args[4].integer(),
                x1: args[5].integer(),
                y0: args[6].integer(),
                y1: args[7].integer(),
                out: buffers.i32(args[8])
            ))
        case "lettering_support":
            try NativeTranslationPixelKernels.lettering_support(
                rgba: buffers.u8(args[0]),
                w: args[1].integer(),
                h: args[2].integer(),
                l: args[3].double(),
                r: args[4].double(),
                t: args[5].double(),
                b: args[6].double(),
                ir: args[7].integer(),
                ig: args[8].integer(),
                ib: args[9].integer(),
                out: buffers.i32(args[10])
            )
            return nil
        case "glyph_index":
            try NativeTranslationPixelKernels.glyph_index(
                rgba: buffers.u8(args[0]),
                n: args[1].integer(),
                start: buffers.i32(args[2]),
                order: buffers.i32(args[3]),
                cursor: buffers.i32(args[4])
            )
            return nil
        case "glyph_seed":
            return Int(try NativeTranslationPixelKernels.glyph_seed(
                rgba: buffers.u8(args[0]),
                w: args[1].integer(),
                h: args[2].integer(),
                cr: args[3].integer(),
                cg: args[4].integer(),
                cb: args[5].integer(),
                left: args[6].double(),
                right: args[7].double(),
                top: args[8].double(),
                bottom: args[9].double(),
                min_total: args[10].double(),
                vertical: args[11].integer(),
                origin: args[12].double(),
                span: args[13].double(),
                start: buffers.i32(args[14]),
                order: buffers.i32(args[15]),
                mask: buffers.u8(args[16]),
                seen: buffers.u8(args[17]),
                queue: buffers.i32(args[18]),
                core: buffers.i32(args[19]),
                stats: buffers.i32(args[20])
            ))
        case "glyph_enclosure":
            try NativeTranslationPixelKernels.glyph_enclosure(
                rgba: buffers.u8(args[0]),
                w: args[1].integer(),
                h: args[2].integer(),
                core: buffers.i32(args[3]),
                len: args[4].integer(),
                stride: args[5].integer(),
                or: args[6].integer(),
                og: args[7].integer(),
                ob: args[8].integer(),
                out: buffers.i32(args[9])
            )
            return nil
        case "stroke_glyph":
            try NativeTranslationPixelKernels.stroke_glyph(
                rgba: buffers.u8(args[0]),
                w: args[1].integer(),
                h: args[2].integer(),
                fr: args[3].integer(),
                fg: args[4].integer(),
                fb: args[5].integer(),
                left: args[6].double(),
                right: args[7].double(),
                top: args[8].double(),
                bottom: args[9].double(),
                mask: buffers.u8(args[10]),
                seen: buffers.u8(args[11]),
                exterior: buffers.u8(args[12]),
                queue: buffers.i32(args[13]),
                core: buffers.i32(args[14]),
                heights: buffers.i32(args[15]),
                out: buffers.i32(args[16])
            )
            return nil
        case "stroke_first":
            return Int(try NativeTranslationPixelKernels.stroke_first(
                rgba: buffers.u8(args[0]),
                w: args[1].integer(),
                h: args[2].integer(),
                core: buffers.i32(args[3]),
                len: args[4].integer(),
                stride: args[5].integer(),
                reach: args[6].integer(),
                fr: args[7].integer(),
                fg: args[8].integer(),
                fb: args[9].integer(),
                sx: buffers.i32(args[10]),
                sy: buffers.i32(args[11]),
                first: buffers.i32(args[12])
            ))
        case "stroke_seed":
            return Int(try NativeTranslationPixelKernels.stroke_seed(
                rgba: buffers.u8(args[0]),
                w: args[1].integer(),
                h: args[2].integer(),
                samples: args[3].integer(),
                sx: buffers.i32(args[4]),
                sy: buffers.i32(args[5]),
                first: buffers.i32(args[6]),
                reach: args[7].integer(),
                fr: args[8].integer(),
                fg: args[9].integer(),
                fb: args[10].integer(),
                sr: args[11].integer(),
                sg: args[12].integer(),
                sb: args[13].integer(),
                rejoins: args[14].integer(),
                exterior: buffers.u8(args[15]),
                bands: buffers.i32(args[16]),
                stats: buffers.i32(args[17])
            ))
        case "bins_inside":
            return Int(try NativeTranslationPixelKernels.bins_inside(
                rgba: buffers.u8(args[0]),
                w: args[1].integer(),
                h: args[2].integer(),
                left: args[3].double(),
                right: args[4].double(),
                top: args[5].double(),
                bottom: args[6].double(),
                check_alpha: args[7].integer(),
                counts: buffers.i32(args[8]),
                sums: buffers.i32(args[9]),
                order: buffers.i32(args[10])
            ))
        case "transpose_rgba":
            try NativeTranslationPixelKernels.transpose_rgba(
                src: buffers.u8(args[0]),
                dst: buffers.u8(args[1]),
                w: args[2].integer(),
                h: args[3].integer()
            )
            return nil
        case "outlined_components":
            return Int(try NativeTranslationPixelKernels.outlined_components(
                rgba: buffers.u8(args[0]),
                w: args[1].integer(),
                h: args[2].integer(),
                allow_dark: args[3].integer(),
                white: buffers.u8(args[4]),
                seen: buffers.u8(args[5]),
                queue: buffers.i32(args[6]),
                counts: buffers.i32(args[7]),
                sums: buffers.i32(args[8]),
                keys: buffers.i32(args[9]),
                out: buffers.i32(args[10])
            ))
        case "caption_mask":
            return Int(try NativeTranslationPixelKernels.caption_mask(
                rgba: buffers.u8(args[0]),
                w: args[1].integer(),
                h: args[2].integer(),
                ir: args[3].integer(),
                ig: args[4].integer(),
                ib: args[5].integer(),
                tolerance: args[6].integer(),
                radius: args[7].integer(),
                il: args[8].double(),
                it: args[9].double(),
                iright: args[10].double(),
                ibottom: args[11].double(),
                dark_ink: args[12].integer(),
                interior_min: args[13].double(),
                near: buffers.u8(args[14]),
                mask: buffers.u8(args[15]),
                dots: buffers.u8(args[16]),
                halo: buffers.u8(args[17]),
                seen: buffers.u8(args[18]),
                queue: buffers.i32(args[19]),
                stats: buffers.i32(args[20])
            ))
        case "caption_periodic":
            return Int(try NativeTranslationPixelKernels.caption_periodic(
                dots: buffers.u8(args[0]),
                w: args[1].integer(),
                h: args[2].integer(),
                axis: args[3].integer()
            ))
        case "caption_exposed":
            try NativeTranslationPixelKernels.caption_exposed(
                rgba: buffers.u8(args[0]),
                w: args[1].integer(),
                mask: buffers.u8(args[2]),
                halo: buffers.u8(args[3]),
                textured: args[4].integer(),
                x0: args[5].integer(),
                x1: args[6].integer(),
                y0: args[7].integer(),
                y1: args[8].integer(),
                vertical: args[9].integer(),
                start: args[10].double(),
                length: args[11].double(),
                r: buffers.u8(args[12]),
                g: buffers.u8(args[13]),
                b: buffers.u8(args[14]),
                band: buffers.u8(args[15]),
                stats: buffers.i32(args[16])
            )
            return nil
        case "columns_sort":
            try NativeTranslationPixelKernels.columns_sort(
                r: buffers.u8(args[0]),
                g: buffers.u8(args[1]),
                b: buffers.u8(args[2]),
                band: buffers.u8(args[3]),
                count: args[4].integer(),
                ro: buffers.u8(args[5]),
                go: buffers.u8(args[6]),
                bo: buffers.u8(args[7]),
                bando: buffers.u8(args[8]),
                offsets: buffers.i32(args[9])
            )
            return nil
        case "columns_bins":
            return Int(try NativeTranslationPixelKernels.columns_bins(
                r: buffers.u8(args[0]),
                g: buffers.u8(args[1]),
                b: buffers.u8(args[2]),
                count: args[3].integer(),
                counts: buffers.i32(args[4]),
                sums: buffers.i32(args[5]),
                order: buffers.i32(args[6])
            ))
        case "columns_support":
            try NativeTranslationPixelKernels.columns_support(
                r: buffers.u8(args[0]),
                g: buffers.u8(args[1]),
                b: buffers.u8(args[2]),
                count: args[3].integer(),
                m0: args[4].double(),
                m1: args[5].double(),
                m2: args[6].double(),
                out: buffers.i32(args[7])
            )
            return nil
        case "columns_range":
            return Int(try NativeTranslationPixelKernels.columns_range(
                r: buffers.u8(args[0]),
                g: buffers.u8(args[1]),
                b: buffers.u8(args[2]),
                count: args[3].integer(),
                hist: buffers.i32(args[4])
            ))
        case "columns_brighter":
            try NativeTranslationPixelKernels.columns_brighter(
                r: buffers.u8(args[0]),
                g: buffers.u8(args[1]),
                b: buffers.u8(args[2]),
                band: buffers.u8(args[3]),
                count: args[4].integer(),
                m0: args[5].double(),
                m1: args[6].double(),
                m2: args[7].double(),
                out: buffers.i32(args[8])
            )
            return nil
        case "columns_sum":
            try NativeTranslationPixelKernels.columns_sum(
                r: buffers.u8(args[0]),
                g: buffers.u8(args[1]),
                b: buffers.u8(args[2]),
                from: args[3].integer(),
                to: args[4].integer(),
                out: buffers.i32(args[5])
            )
            return nil
        case "harmonic_fill":
            try NativeTranslationPixelKernels.harmonic_fill(
                p: buffers.u8(args[0]),
                w: args[1].integer(),
                n: args[2].integer(),
                queue: buffers.i32(args[3]),
                tail: args[4].integer(),
                blocked: buffers.u8(args[5]),
                paint: buffers.u8(args[6]),
                accelerated: args[7].integer(),
                work: buffers.f32(args[8]),
                links: buffers.u8(args[9])
            )
            return nil
        case "exemplar_fill":
            return Int(try NativeTranslationPixelKernels.exemplar_fill(
                rgba: buffers.u8(args[0]),
                w: args[1].integer(),
                h: args[2].integer(),
                mask: buffers.u8(args[3]),
                forbidden: buffers.u8(args[4]),
                fg: buffers.f64(args[5]),
                coeff: buffers.f64(args[6]),
                erased: args[7].integer(),
                work: buffers.u8(args[8]),
                pending: buffers.u8(args[9]),
                residual: buffers.f32(args[10]),
                filled: buffers.f32(args[11]),
                integral: buffers.i32(args[12]),
                output: buffers.u8(args[13]),
                donors: buffers.i32(args[14]),
                cell: buffers.f64(args[15]),
                grid_x: buffers.i32(args[16]),
                grid_y: buffers.i32(args[17]),
                stats: buffers.f64(args[18])
            ))
        case "enclosed_paper":
            return Int(try NativeTranslationPixelKernels.enclosed_paper(
                rgba: buffers.u8(args[0]),
                w: args[1].integer(),
                h: args[2].integer(),
                l: args[3].integer(),
                t: args[4].integer(),
                r: args[5].integer(),
                bottom: args[6].integer(),
                rects: buffers.f64(args[7]),
                aux_n: args[8].integer(),
                exc_n: args[9].integer(),
                paper: buffers.u8(args[10]),
                seen: buffers.u8(args[11]),
                q: buffers.i32(args[12]),
                best: buffers.i32(args[13]),
                region: buffers.u8(args[14]),
                outside: buffers.u8(args[15]),
                points: buffers.i32(args[16]),
                meta: buffers.i32(args[17]),
                output: buffers.u8(args[18]),
                safe: buffers.u8(args[19]),
                stats: buffers.i32(args[20])
            ))
        case "local_components":
            return Int(try NativeTranslationPixelKernels.local_components(
                rgba: buffers.u8(args[0]),
                w: args[1].integer(),
                h: args[2].integer(),
                l: args[3].integer(),
                t: args[4].integer(),
                right: args[5].integer(),
                bottom: args[6].integer(),
                bg: buffers.f64(args[7]),
                bmax: args[8].double(),
                excluded: buffers.u8(args[9]),
                ink: buffers.u8(args[10]),
                seen: buffers.u8(args[11]),
                safe: buffers.u8(args[12]),
                q: buffers.i32(args[13]),
                paint: buffers.u8(args[14]),
                member: buffers.u8(args[15]),
                output: buffers.u8(args[16]),
                parts: buffers.i32(args[17]),
                part_capacity: args[18].integer(),
                points: buffers.i32(args[19]),
                stats: buffers.i32(args[20])
            ))
        case "pixel_classes":
            try NativeTranslationPixelKernels.pixel_classes(
                rgba: buffers.u8(args[0]),
                n: args[1].integer(),
                colors: buffers.f64(args[2]),
                flags: args[3].integer(),
                ink_tolerance: args[4].double(),
                halo_separation: args[5].double(),
                raw: buffers.u8(args[6]),
                observed: buffers.u8(args[7]),
                protected: buffers.u8(args[8])
            )
            return nil
        default: throw FixtureError.missingKernel
        }
    }

    private static let kernelNames = [
        "lettering_rays",
        "lettering_support",
        "glyph_index",
        "glyph_seed",
        "glyph_enclosure",
        "stroke_glyph",
        "stroke_first",
        "stroke_seed",
        "bins_inside",
        "transpose_rgba",
        "outlined_components",
        "caption_mask",
        "caption_periodic",
        "caption_exposed",
        "columns_sort",
        "columns_bins",
        "columns_support",
        "columns_range",
        "columns_brighter",
        "columns_sum",
        "harmonic_fill",
        "exemplar_fill",
        "enclosed_paper",
        "local_components",
        "pixel_classes"
    ]

    /// Expected bytes are produced by the immutable pre-port WASM, never by the Swift bridge.
    /// One allocation preserves the original scratch aliases and guard bytes around each buffer.
    @Test func allExportedKernelsMatchFrozenWASMThroughSwiftBridge() throws {
        let fixtures = try Self.manifest().cases
        #expect(Set(fixtures.map(\.name)) == Set(Self.kernelNames))
        #expect(NativeTranslationPixelKernels.exportedKernelCount == Self.kernelNames.count)
        for kernel in Self.kernelNames {
            let selected = fixtures.filter { $0.name == kernel }
            #expect(selected.count >= 3, "Missing semantic fixtures for \(kernel)")
            for fixture in selected {
                let buffers = try Buffers(fixture)
                let returns = try fixture.calls.map { try execute($0, buffers: buffers) }
                #expect(returns == fixture.expectedReturns, "Return mismatch in \(fixture.id)")
                let actual = Data(buffers.arena.values)
                let firstDifference = zip(actual, fixture.expectedData).enumerated().first { $0.element.0 != $0.element.1 }?.offset
                #expect(actual == fixture.expectedData,
                        "Arena mismatch in \(fixture.id), first byte \(String(describing: firstDifference)); includes RGB, masks, Float32/Float64 scratch and allocation guards")
            }
        }
    }

    @Test func invalidBridgeInputsAreRejectedBeforeNativeMutation() throws {
        let bytes = try NativeKernelBuffer<UInt8>(values: [20, 30, 40, 255])
        let out = try NativeKernelBuffer<Int32>(values: [17, 18, 19, 20])
        #expect(throws: NativeTranslationPixelKernels.KernelError.self) {
            try NativeTranslationPixelKernels.lettering_support(rgba: bytes, w: -1, h: 1,
                l: 0, r: 1, t: 0, b: 1, ir: 20, ig: 30, ib: 40, out: out)
        }
        #expect(throws: NativeTranslationPixelKernels.KernelError.self) {
            try NativeTranslationPixelKernels.lettering_support(rgba: bytes, w: 1, h: 1,
                l: .infinity, r: 1, t: 0, b: 1, ir: 20, ig: 30, ib: 40, out: out)
        }
        #expect(throws: NativeTranslationPixelKernels.KernelError.self) {
            try NativeTranslationPixelKernels.lettering_support(rgba: bytes, w: 1, h: 1,
                l: 0, r: 1, t: 0, b: 1, ir: 256, ig: 30, ib: 40, out: out)
        }
        #expect(throws: NativeTranslationPixelKernels.KernelError.self) {
            try NativeTranslationPixelKernels.lettering_support(rgba: bytes, w: 2, h: 1,
                l: 0, r: 1, t: 0, b: 1, ir: 20, ig: 30, ib: 40, out: out)
        }
        #expect(bytes.values == [20, 30, 40, 255])
        #expect(out.values == [17, 18, 19, 20])

        let queue = try NativeKernelBuffer<Int32>(values: [0])
        let rgba = try NativeKernelBuffer<UInt8>(count: 36)
        let mask = try NativeKernelBuffer<UInt8>(count: 9)
        let work = try NativeKernelBuffer<Float>(count: 27)
        let links = try NativeKernelBuffer<UInt8>(count: 1)
        // Harmonic fill reads all four neighbors; even a valid pixel index on an edge is unsafe.
        #expect(throws: NativeTranslationPixelKernels.KernelError.self) {
            try NativeTranslationPixelKernels.harmonic_fill(p: rgba, w: 3, n: 9, queue: queue,
                tail: 1, blocked: mask, paint: mask, accelerated: 1, work: work, links: links)
        }
        queue[0] = 9
        #expect(throws: NativeTranslationPixelKernels.KernelError.self) {
            try NativeTranslationPixelKernels.harmonic_fill(p: rgba, w: 3, n: 9, queue: queue,
                tail: 1, blocked: mask, paint: mask, accelerated: 1, work: work, links: links)
        }
        #expect(rgba.values == Array(repeating: UInt8(0), count: 36))
        #expect(work.values == Array(repeating: Float(0), count: 27))
    }

    @Test func borrowedScratchViewsValidateBoundsAlignmentAndRetainStorage() throws {
        var parent: NativeKernelBuffer<Double>? = try NativeKernelBuffer(values: [0, 0])
        let child = try parent!.view(as: UInt8.self, byteOffset: 0, count: 16)
        let grandchild = try child.view(as: Int32.self, byteOffset: 8, count: 2)
        #expect(throws: NativeTranslationPixelKernels.KernelError.self) {
            try child.view(as: Int32.self, byteOffset: 1, count: 1)
        }
        #expect(throws: NativeTranslationPixelKernels.KernelError.self) {
            try child.view(as: Double.self, byteOffset: 8, count: 2)
        }
        #expect(throws: NativeTranslationPixelKernels.KernelError.self) {
            try child.view(as: UInt8.self, byteOffset: -1, count: 1)
        }
        #expect(throws: NativeTranslationPixelKernels.KernelError.self) {
            try child.view(as: UInt8.self, byteOffset: 0, count: -1)
        }
        parent = nil
        grandchild[0] = 0x01020304
        #expect(Array(child.values[8..<12]) == [4, 3, 2, 1])
        #expect(grandchild.values == [0x01020304, 0])
    }
}
