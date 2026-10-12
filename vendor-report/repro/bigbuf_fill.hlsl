// Writes a known value at each probe position through a raw root UAV.
RWByteAddressBuffer dst : register(u1);
StructuredBuffer<uint> probes : register(t5);
[numthreads(64, 1, 1)]
void main(uint i : SV_DispatchThreadID)
{
    uint idx = probes[i];
    dst.Store(idx * 4, (idx * 2654435761u) ^ 0x5bd1e995u);
}
