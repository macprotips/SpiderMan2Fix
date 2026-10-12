// Reads a 2 GB buffer at the probe positions through every kind of view.
Buffer<uint> tb : register(t0);            // typed R32_UINT, 536M elements
Buffer<uint4> tb4 : register(t1);          // typed R32G32B32A32_UINT, 134M elements
StructuredBuffer<uint> sb : register(t2);  // structured, stride 4
ByteAddressBuffer rb : register(t3);       // raw
StructuredBuffer<uint> probes : register(t4);
RWStructuredBuffer<uint4> outb : register(u0);
[numthreads(64, 1, 1)]
void main(uint i : SV_DispatchThreadID)
{
    uint idx = probes[i];
    outb[i] = uint4(tb[idx], tb4[idx >> 2][idx & 3], sb[idx], rb.Load(idx * 4));
}
