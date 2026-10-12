Buffer<uint> pool : register(t1);
RWStructuredBuffer<uint> result : register(u0);
[numthreads(64, 1, 1)]
void main(uint i : SV_DispatchThreadID) { result[i] = pool[i * 3] + pool[i + 268435456]; }
