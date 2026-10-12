import CShaderFix
import Foundation

/// One of the game's shaders that the fix rewrites, and the result it must produce.
public struct PoolShader: Equatable {
    /// Hash of the game's original shader (64-bit FNV-1 of the DXIL container).
    public var sourceHash: UInt64
    /// The typed buffer view that becomes raw: an SRV (t register), or with `uav` a
    /// RWBuffer<uint> UAV (u register) whose writes become raw too.
    public var space: Int32
    public var register: Int32
    public var uav: Bool
    /// Hash of the verified rewritten shader; nil skips the check (tests only).
    public var resultHash: UInt64?

    public init(sourceHash: UInt64, space: Int32, register: Int32, uav: Bool = false, resultHash: UInt64?) {
        self.sourceHash = sourceHash
        self.space = space
        self.register = register
        self.uav = uav
        self.resultHash = resultHash
    }

    /// The file the d3d12.dll shim loads in place of the original.
    public var fileName: String { "sm2fix-pool-" + hex(sourceHash) + ".dxil" }

    /// The shaders of Marvel's Spider-Man 2 that read (T-pose) or write (symbiote) the 2 GB mesh
    /// pool through typed views, and the hashes of the rewritten shaders verified in the game.
    public static let spiderMan2: [PoolShader] = [
        PoolShader(sourceHash: 0x3d50_acdb_571d_ce22, space: 0, register: 1, resultHash: 0x589e_d5a9_fddc_545f), // CS_ModelSkinning
        PoolShader(sourceHash: 0x1490_2794_dd71_34e4, space: 0, register: 0, resultHash: 0xee43_4fbf_42f2_4d08), // vertex morph
        // The symbiote's spline meshes: their triangles, written past element 2^28 of the pool.
        PoolShader(sourceHash: 0x9538_ca33_c087_a84c, space: 0, register: 1, uav: true,
                   resultHash: 0xce7b_2801_15b2_aa10),                                                         // CS_AnimSplineMeshGenIndices
        PoolShader(sourceHash: 0x125a_4957_ab64_d24d, space: 0, register: 1, uav: true,
                   resultHash: 0xb84c_589e_5ae4_b5c5),                                                         // ...GenIndicesFinalize
    ]
}

func hex(_ value: UInt64) -> String {
    let digits = String(value, radix: 16)
    return String(repeating: "0", count: max(0, 16 - digits.count)) + digits
}

public func shaderHash(_ data: Data) -> UInt64 {
    data.withUnsafeBytes { sf_shader_hash($0.baseAddress, $0.count) }
}

public enum ShaderBuildError: Error, LocalizedError, Equatable {
    case toolsMissing
    case cantReadGame(String)
    case shaderNotFound
    case toolFailed(String, String)
    case rewriteFailed(String)
    case unexpectedResult

    public var errorDescription: String? {
        switch self {
        case .toolsMissing:
            return "The app is missing its shader tools. Download it again."
        case .cantReadGame(let reason):
            return "Couldn't read Spider-Man2.exe: \(reason)"
        case .shaderNotFound:
            return "This version of Spider-Man 2 isn't supported yet: the shaders the fix rewrites aren't in its Spider-Man2.exe. A game update may have changed them."
        case .toolFailed(let tool, let output):
            return "Building the fix's shaders failed (\(tool)): \(output.trimmingCharacters(in: .whitespacesAndNewlines).suffix(300))"
        case .rewriteFailed(let reason):
            return "Building the fix's shaders failed: \(reason)"
        case .unexpectedResult:
            return "The rebuilt shaders don't match the verified ones, so the fix wasn't installed."
        }
    }
}

/// Builds the fix's shaders from the game's own Spider-Man2.exe, using Microsoft's shader
/// tools (dxc, dxa, dxv) bundled with the app: extract, disassemble, rewrite, reassemble,
/// validate and sign. The result is checked against the verified shader's hash.
public struct ShaderBuilder {
    /// Folder with the dxc, dxa and dxv executables.
    public let tools: URL
    public let runner: CommandRunner

    public init(tools: URL, runner: CommandRunner = ProcessRunner()) {
        self.tools = tools
        self.runner = runner
    }

    public var toolsPresent: Bool {
        ["dxc", "dxa", "dxv"].allSatisfy { FileManager.default.isExecutableFile(atPath: tools.appendingPathComponent($0).path) }
    }

    /// The original shader, found in the game's exe (or any file holding DXBC containers).
    public func extract(_ shader: PoolShader, from exe: Data) -> Data? {
        exe.withUnsafeBytes { raw -> Data? in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            var offset = 0, size = 0
            guard sf_find_container(base, raw.count, shader.sourceHash, &offset, &size) != 0 else { return nil }
            return Data(bytes: base + offset, count: size)
        }
    }

    /// Rewrites one shader container: its typed SRV (or with `uav`, RWBuffer<uint> UAV) at
    /// (space, register) becomes raw.
    public func rewrite(_ container: Data, space: Int32, register: Int32, uav: Bool = false) throws -> Data {
        guard toolsPresent else { throw ShaderBuildError.toolsMissing }
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("sm2fix-shader-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let original = work.appendingPathComponent("original.dxil")
        let listing = work.appendingPathComponent("original.ll")
        let edited = work.appendingPathComponent("edited.ll")
        let assembled = work.appendingPathComponent("assembled.dxil")
        let signed = work.appendingPathComponent("signed.dxil")
        try container.write(to: original)

        try tool("dxc", ["-dumpbin", original.path, "-Fc", listing.path])
        guard let text = try? String(contentsOf: listing, encoding: .utf8) else {
            throw ShaderBuildError.rewriteFailed("no disassembly")
        }
        var message = [CChar](repeating: 0, count: 256)
        let rewritten = uav ? sf_typed_to_raw_uav(text, space, register, nil, nil, nil, &message, message.count)
                            : sf_typed_to_raw(text, space, register, nil, nil, &message, message.count)
        guard let rawText = rewritten else {
            throw ShaderBuildError.rewriteFailed(String(cString: message))
        }
        defer { free(rawText) }
        guard let named = sf_name_values(rawText) else { throw ShaderBuildError.rewriteFailed("out of memory") }
        defer { free(named) }
        try String(cString: named).write(to: edited, atomically: true, encoding: .utf8)

        try tool("dxa", ["-o", assembled.path, edited.path])
        try tool("dxv", [assembled.path, "-o", signed.path])
        return try Data(contentsOf: signed)
    }

    /// Builds every shader from the game's exe and returns file name -> contents.
    public func build(_ shaders: [PoolShader], fromGame exe: URL) throws -> [String: Data] {
        guard toolsPresent else { throw ShaderBuildError.toolsMissing }
        let data: Data
        do { data = try Data(contentsOf: exe, options: .alwaysMapped) } catch {
            throw ShaderBuildError.cantReadGame(error.localizedDescription)
        }
        var files: [String: Data] = [:]
        for shader in shaders {
            guard let original = extract(shader, from: data) else { throw ShaderBuildError.shaderNotFound }
            let result = try rewrite(original, space: shader.space, register: shader.register, uav: shader.uav)
            if let expected = shader.resultHash, shaderHash(result) != expected {
                throw ShaderBuildError.unexpectedResult
            }
            files[shader.fileName] = result
        }
        return files
    }

    private func tool(_ name: String, _ arguments: [String]) throws {
        let result = runner.run(tools.appendingPathComponent(name), arguments, environment: [:], timeout: 120)
        guard result.status == 0 else { throw ShaderBuildError.toolFailed(name, result.output) }
    }
}
