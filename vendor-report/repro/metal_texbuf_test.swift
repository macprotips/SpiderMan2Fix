// Native Metal check: reads a ~2 GB MTLBuffer at large element indices through an
// r32Uint texture buffer, an rgba32Uint texture buffer and as plain device memory.
// No Wine or D3DMetal involved.
//
//   swiftc -O metal_texbuf_test.swift -o metal_texbuf_test && ./metal_texbuf_test
import Foundation
import Metal

let shader = """
#include <metal_stdlib>
using namespace metal;
kernel void probe(texture_buffer<uint, access::read> tb [[texture(0)]],
                  texture_buffer<uint, access::read> tb4 [[texture(1)]],
                  device const uint *raw [[buffer(0)]],
                  device const uint *index [[buffer(1)]],
                  device uint4 *result [[buffer(2)]],
                  constant uint &count [[buffer(3)]],
                  uint i [[thread_position_in_grid]])
{
    if (i >= count) return;
    uint k = index[i];
    result[i] = uint4(tb.read(k).r, tb4.read(k >> 2)[k & 3], raw[k], 0);
}
"""

func fail(_ message: String) -> Never {
    print("FAILED: \(message)")
    exit(1)
}

guard let device = MTLCreateSystemDefaultDevice() else { fail("no Metal device") }
let family = (1001...1020).last { MTLGPUFamily(rawValue: $0).map(device.supportsFamily) ?? false }
print("device: \(device.name), highest Apple GPU family: \(family.map { "apple\($0 - 1000)" } ?? "none")")
print("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
print("maxBufferLength: \(device.maxBufferLength)")

let bytes = 2_147_483_648 - 65_536            // just under 2 GB, like the game's pool
let count = bytes / 4                          // 536,854,528 32-bit elements
guard bytes <= device.maxBufferLength else { fail("buffer larger than maxBufferLength") }
guard let buffer = device.makeBuffer(length: bytes, options: .storageModeShared) else { fail("2 GB buffer") }

var probes: [UInt32] = [0, 1, 12_345]
for shift in 20...28 {
    let p = 1 << shift
    probes += [UInt32(p - 1), UInt32(p), UInt32(p + 4)]
}
probes += [335_544_320, 402_653_184, UInt32(count - 8), UInt32(count - 1)]
let memory = buffer.contents().bindMemory(to: UInt32.self, capacity: count)
func expected(_ k: UInt32) -> UInt32 { (k &* 2_654_435_761) ^ 0x5bd1_e995 }
for k in probes { memory[Int(k)] = expected(k) }

let alignment = device.minimumTextureBufferAlignment(for: .r32Uint)
print("texture buffer alignment: \(alignment) bytes")
let desc1 = MTLTextureDescriptor.textureBufferDescriptor(with: .r32Uint, width: count,
                                                         resourceOptions: .storageModeShared, usage: .shaderRead)
let desc4 = MTLTextureDescriptor.textureBufferDescriptor(with: .rgba32Uint, width: count / 4,
                                                         resourceOptions: .storageModeShared, usage: .shaderRead)
guard let tex1 = buffer.makeTexture(descriptor: desc1, offset: 0, bytesPerRow: count * 4) else { fail("r32Uint texture buffer") }
guard let tex4 = buffer.makeTexture(descriptor: desc4, offset: 0, bytesPerRow: count * 4) else { fail("rgba32Uint texture buffer") }
print("r32Uint texture buffer: width \(tex1.width) texels; rgba32Uint: width \(tex4.width) texels")

let library: MTLLibrary
do { library = try device.makeLibrary(source: shader, options: nil) } catch { fail("shader: \(error)") }
guard let function = library.makeFunction(name: "probe"),
      let pipeline = try? device.makeComputePipelineState(function: function),
      let queue = device.makeCommandQueue(),
      let indexBuffer = device.makeBuffer(bytes: probes, length: probes.count * 4, options: .storageModeShared),
      let results = device.makeBuffer(length: probes.count * 16, options: .storageModeShared),
      let commands = queue.makeCommandBuffer(),
      let encoder = commands.makeComputeCommandEncoder() else { fail("pipeline setup") }
var n = UInt32(probes.count)
encoder.setComputePipelineState(pipeline)
encoder.setTexture(tex1, index: 0)
encoder.setTexture(tex4, index: 1)
encoder.setBuffer(buffer, offset: 0, index: 0)
encoder.setBuffer(indexBuffer, offset: 0, index: 1)
encoder.setBuffer(results, offset: 0, index: 2)
encoder.setBytes(&n, length: 4, index: 3)
encoder.dispatchThreadgroups(MTLSize(width: (probes.count + 63) / 64, height: 1, depth: 1),
                             threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
encoder.endEncoding()
commands.commit()
commands.waitUntilCompleted()
if let error = commands.error { fail("GPU: \(error)") }

let out = results.contents().bindMemory(to: UInt32.self, capacity: probes.count * 4)
func hex(_ v: UInt32) -> String { String(format: "%08x", v) }
print("")
print("element      expected   r32Uint    rgba32Uint raw")
var bad = [0, 0, 0]
var firstBad: [UInt32?] = [nil, nil, nil]
for (i, k) in probes.enumerated() {
    let want = expected(k)
    var cells: [String] = []
    for j in 0..<3 {
        let got = out[i * 4 + j]
        if got != want {
            bad[j] += 1
            if firstBad[j] == nil { firstBad[j] = k }
        }
        cells.append(hex(got) + (got == want ? " " : "*"))
    }
    print(String(k).padding(toLength: 12, withPad: " ", startingAt: 0) + " " + hex(want) + "   " + cells.joined(separator: "  "))
}
print("")
for (j, name) in ["r32Uint texture buffer", "rgba32Uint texture buffer", "raw device memory"].enumerated() {
    if bad[j] == 0 {
        print("\(name): all \(probes.count) probes correct")
    } else {
        print("\(name): WRONG at \(bad[j]) probes, first at element \(firstBad[j]!)")
    }
}
print(bad.allSatisfy { $0 == 0 } ? "RESULT: all reads correct" : "RESULT: some reads wrong")
