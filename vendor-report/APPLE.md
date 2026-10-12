# D3DMetal: typed buffer views wider than 2^28 elements read as zero

**For:** Apple, Feedback Assistant (Game Porting Toolkit / D3DMetal)

**Suggested title:** D3DMetal: typed buffer SRVs with more than 268,435,456 elements return 0 past that element (Marvel's Spider-Man 2 characters stuck in T-pose on M1 to M4)

---

## Summary

On Apple M1 to M4 Macs, D3DMetal accepts a Direct3D 12 typed buffer SRV with more than
268,435,456 (2^28) elements, but every shader read at element 2^28 or above returns 0.
The view is created without an error or warning. Raw, structured and wider-format typed
views over the same memory read correctly to the end of the buffer.

2^28 is Metal's maximum texture buffer width. Metal's API validation rejects a texture
buffer this wide with the message *"MTLTextureDescriptor has width (536854528) greater
than the maximum allowed size of 268435456"*. D3DMetal appears to back typed buffer views
with texture buffers and does not handle views that exceed this limit.

Marvel's Spider-Man 2 reads its 2 GB character mesh pool through typed `R32_UINT` views of
536,346,624 elements. Characters whose mesh data is stored above element 2^28 are never
skinned and render in their bind pose (T-pose). The game works on Windows GPUs and,
according to users, on M5 Macs.

## Environment

| | |
| --- | --- |
| Mac | MacBook Pro, Apple M3 Max |
| macOS | 27.0.1 |
| Translation layer | D3DMetal, as bundled with CrossOver (Game Porting Toolkit 4.0b2 per the Metal HUD) |
| CrossOver | [version from CrossOver › About CrossOver] |
| Game | Marvel's Spider-Man 2, Steam app 2651280, Direct3D 12 |
| Also reported on | M1, M2 and M4 (same symptom, user reports). M5 reported unaffected. |

## Steps to reproduce (standalone, about one minute)

The attached `repro/bigbuf_test.exe` is a 270-line D3D12 test, with full source in
`repro/bigbuf_test.c` and its HLSL in the same folder.

1. Copy the `repro` folder to the Mac.
2. Run the test in any CrossOver bottle that uses D3DMetal, with the command below.
3. Read `report.txt`.

```sh
cd repro
"/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine" \
    --bottle "<bottle name>" bigbuf_test.exe report.txt
```

If it stops before printing a table, run it again with `WINEDLLOVERRIDES="winemac.drv=d"`
in front of the command.

What the test does:

1. Creates one committed buffer of 2,147,418,112 bytes (just under 2 GB) in a default heap.
2. Writes a known value at 34 probe positions between element 0 and element 536,854,527,
   using a raw root UAV.
3. Reads the same positions back in one compute dispatch through four SRVs of that buffer:

   | View | Format | NumElements | HLSL type |
   | --- | --- | --- | --- |
   | Typed | `DXGI_FORMAT_R32_UINT` | 536,854,528 | `Buffer<uint>` |
   | Typed, 16-byte | `DXGI_FORMAT_R32G32B32A32_UINT` | 134,213,632 | `Buffer<uint4>` |
   | Structured | stride 4 | 536,854,528 | `StructuredBuffer<uint>` |
   | Raw | `R32_TYPELESS`, `D3D12_BUFFER_SRV_FLAG_RAW` | 536,854,528 | `ByteAddressBuffer` |

## Expected result

All four views return the written value at every probe, as on Windows drivers and on
vkd3d-proton with Mesa lavapipe, where we ran the same test.

## Actual result (M3 Max, macOS 27.0.1)

The typed `R32_UINT` view returns 0 from element 268,435,456 onward. The other three views
are correct everywhere. Excerpt from `repro/results/bigbuf-report-M3-Max.txt`:

| Element | Expected | R32_UINT | RGBA32_UINT | Structured | Raw |
| ---: | --- | --- | --- | --- | --- |
| 134,217,728 | d3d1e995 | d3d1e995 | d3d1e995 | d3d1e995 | d3d1e995 |
| 268,435,455 | 2a196fda | 2a196fda | 2a196fda | 2a196fda | 2a196fda |
| **268,435,456** | 4bd1e995 | **00000000** | 4bd1e995 | 4bd1e995 | 4bd1e995 |
| 268,435,460 | d30c0f51 | **00000000** | d30c0f51 | d30c0f51 | d30c0f51 |
| 335,544,320 | 8fd1e995 | **00000000** | 8fd1e995 | 8fd1e995 | 8fd1e995 |
| 402,653,184 | c3d1e995 | **00000000** | c3d1e995 | c3d1e995 | c3d1e995 |
| 536,854,527 | f88dafda | **00000000** | f88dafda | f88dafda | f88dafda |

Element 268,435,455 is the last one that reads correctly through the typed view.

## Analysis

- **The data and addressing are fine.** The same bytes read correctly through the
  structured and raw views, and through the `R32G32B32A32_UINT` view. That view covers the
  same 2 GB in 134 million elements, which is under the limit.
- **The boundary is exactly 2^28 elements.** That is Metal's maximum texture buffer
  width. Creating an `r32Uint` texture buffer of 536,854,528 texels with API validation
  enabled fails with the message quoted in the summary. See
  `repro/metal_texbuf_test.swift` and `repro/results/metal-validation.txt`.
- **D3DMetal gives no signal.** `CreateShaderResourceView` succeeds, nothing is logged,
  and the reads return 0. To a developer this looks like missing data, not an API limit.
- **D3D12 spec context.** `D3D12_REQ_BUFFER_RESOURCE_TEXEL_COUNT_2_TO_EXP` is 27, so the
  spec only guarantees typed buffer views of 2^27 elements. The game exceeds that
  guarantee. In practice, Windows drivers and, by user reports, D3DMetal on M5 handle
  it. The current failure is silent and wrong data, which no title can detect or work
  around at runtime.
- **Not tested:** typed UAVs over the same limit, and formats other than 32-bit.

## Impact: Marvel's Spider-Man 2

- The game creates `DXGI_FORMAT_R32_UINT` SRVs with `FirstElement = 0` and
  `NumElements = 536,346,624` over its 2 GB mesh pool.
- Two compute shaders read the pool through these views:
  - `CS_ModelSkinning` (DXIL hash `3d50acdb571dce22`, register `t1`, space 0)
  - a vertex morph shader (DXIL hash `14902794dd7134e4`, register `t0`, space 0)

  Hashes are 64-bit FNV-1 over the DXIL container, the same scheme vkd3d-proton uses.
- Meshes stored in the upper half of the pool get zero skinning data and stay in bind
  pose. The upper garments of many NPCs, and sometimes Spider-Man himself, are affected,
  while other parts of the same character animate.

**Confirmed by workaround.** We made a `d3d12.dll` shim that sits between the game and
D3DMetal and changes only two things:

- It creates these large typed views as raw views (`R32_TYPELESS` + `RAW` flag).
- It swaps in versions of the two shaders whose typed loads are replaced with equivalent
  raw loads at `index * 4`.

With the shim, the T-pose is gone on the M3 Max. The session log records one view
converted, both pipelines created, about 801,000 dispatches and zero pipeline failures
(`repro/results/sm2fix-log-with-workaround-M3-Max.txt`). On vkd3d-proton with lavapipe,
the rewritten skinning shader produces bit-identical output to the original. Source:
<https://github.com/macprotips/SpiderMan2Fix>

## Suggested fix

1. When a typed buffer view is wider than the maximum texture buffer width, read it
   without a texture buffer. Typed buffer loads have no filtering, so they can be
   expressed as device-memory loads plus format conversion. For single-channel 32-bit
   formats this is a plain 4-byte load at `FirstElement + index`. Because the view size
   isn't known when the shader is compiled, this needs either a raw-load path for typed
   buffers in general, or a second variant selected when such a view is bound.
2. Until then, report the condition. Log a clear message, at least with the debug layer,
   when `CreateShaderResourceView` or `CreateUnorderedAccessView` gets a typed buffer view
   wider than the limit. Returning 0 without any message is the hardest outcome to
   diagnose.

## Attachments

- `repro/bigbuf_test.exe`, `bigbuf_test.c`, `bigbuf_probe.hlsl`, `bigbuf_fill.hlsl`,
  `bigbuf_shaders.h`: the D3D12 reproduction (x86-64 Windows, builds with MinGW or
  `zig cc`)
- `repro/metal_texbuf_test.swift`: native Metal check of the texture buffer width limit
- `repro/results/bigbuf-report-M3-Max.txt`: full output on the M3 Max
- `repro/results/metal-validation.txt`: Metal validation message
- `repro/results/sm2fix-log-with-workaround-M3-Max.txt`: game session with the workaround

---

## Separate issue (please file on its own): D3D12 timestamps

Found in the same investigation on the same M3 Max. It does not cause the T-pose.

- `ID3D12CommandQueue::GetTimestampFrequency` returns **60**.
- Every `ResolveQueryData(D3D12_QUERY_TYPE_TIMESTAMP, …)` writes **0**. About 15,000
  timestamp queries were resolved in a few minutes of play, measured by an interception
  layer that maps the resolve buffer.
- Occlusion queries in the same session resolve to plausible non-zero values.
- **Expected:** the GPU timestamp frequency and monotonically increasing timestamps, as
  on Windows. Titles that use timestamps for GPU timing or dynamic resolution get no
  usable data.
