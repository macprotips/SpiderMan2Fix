RWBuffer<uint> pool : register(u1);
Buffer<uint> map : register(t1);
[numthreads(64, 1, 1)]
void main(uint i : SV_DispatchThreadID)
{
    uint at = map[i] + 268435456;
    if (pool[at] != 0)
        pool[at + 1] = pool[at] + i;
    pool[i * 3] = (i << 16) | (i + 1);
}
