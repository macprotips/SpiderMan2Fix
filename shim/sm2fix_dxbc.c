#include "sm2fix_dxbc.h"

#include <string.h>

/* ---- MD5 core (RFC 1321), exposing the raw state the DXBC checksum needs. */

struct md5
{
    uint32_t a, b, c, d;
    uint64_t length;
    uint8_t buffer[64];
};

#define F(x, y, z) ((z) ^ ((x) & ((y) ^ (z))))
#define G(x, y, z) ((y) ^ ((z) & ((x) ^ (y))))
#define H(x, y, z) ((x) ^ (y) ^ (z))
#define I(x, y, z) ((y) ^ ((x) | ~(z)))
#define STEP(f, a, b, c, d, x, t, s) \
    (a) += f((b), (c), (d)) + (x) + (t); \
    (a) = (((a) << (s)) | (((a) & 0xffffffff) >> (32 - (s)))); \
    (a) += (b);

static void md5_block(struct md5 *ctx, const uint8_t *p)
{
    uint32_t a = ctx->a, b = ctx->b, c = ctx->c, d = ctx->d, x[16];
    int i;

    for (i = 0; i < 16; i++)
        x[i] = p[i * 4] | (p[i * 4 + 1] << 8) | (p[i * 4 + 2] << 16) | ((uint32_t)p[i * 4 + 3] << 24);

    STEP(F, a, b, c, d, x[0], 0xd76aa478, 7) STEP(F, d, a, b, c, x[1], 0xe8c7b756, 12)
    STEP(F, c, d, a, b, x[2], 0x242070db, 17) STEP(F, b, c, d, a, x[3], 0xc1bdceee, 22)
    STEP(F, a, b, c, d, x[4], 0xf57c0faf, 7) STEP(F, d, a, b, c, x[5], 0x4787c62a, 12)
    STEP(F, c, d, a, b, x[6], 0xa8304613, 17) STEP(F, b, c, d, a, x[7], 0xfd469501, 22)
    STEP(F, a, b, c, d, x[8], 0x698098d8, 7) STEP(F, d, a, b, c, x[9], 0x8b44f7af, 12)
    STEP(F, c, d, a, b, x[10], 0xffff5bb1, 17) STEP(F, b, c, d, a, x[11], 0x895cd7be, 22)
    STEP(F, a, b, c, d, x[12], 0x6b901122, 7) STEP(F, d, a, b, c, x[13], 0xfd987193, 12)
    STEP(F, c, d, a, b, x[14], 0xa679438e, 17) STEP(F, b, c, d, a, x[15], 0x49b40821, 22)
    STEP(G, a, b, c, d, x[1], 0xf61e2562, 5) STEP(G, d, a, b, c, x[6], 0xc040b340, 9)
    STEP(G, c, d, a, b, x[11], 0x265e5a51, 14) STEP(G, b, c, d, a, x[0], 0xe9b6c7aa, 20)
    STEP(G, a, b, c, d, x[5], 0xd62f105d, 5) STEP(G, d, a, b, c, x[10], 0x02441453, 9)
    STEP(G, c, d, a, b, x[15], 0xd8a1e681, 14) STEP(G, b, c, d, a, x[4], 0xe7d3fbc8, 20)
    STEP(G, a, b, c, d, x[9], 0x21e1cde6, 5) STEP(G, d, a, b, c, x[14], 0xc33707d6, 9)
    STEP(G, c, d, a, b, x[3], 0xf4d50d87, 14) STEP(G, b, c, d, a, x[8], 0x455a14ed, 20)
    STEP(G, a, b, c, d, x[13], 0xa9e3e905, 5) STEP(G, d, a, b, c, x[2], 0xfcefa3f8, 9)
    STEP(G, c, d, a, b, x[7], 0x676f02d9, 14) STEP(G, b, c, d, a, x[12], 0x8d2a4c8a, 20)
    STEP(H, a, b, c, d, x[5], 0xfffa3942, 4) STEP(H, d, a, b, c, x[8], 0x8771f681, 11)
    STEP(H, c, d, a, b, x[11], 0x6d9d6122, 16) STEP(H, b, c, d, a, x[14], 0xfde5380c, 23)
    STEP(H, a, b, c, d, x[1], 0xa4beea44, 4) STEP(H, d, a, b, c, x[4], 0x4bdecfa9, 11)
    STEP(H, c, d, a, b, x[7], 0xf6bb4b60, 16) STEP(H, b, c, d, a, x[10], 0xbebfbc70, 23)
    STEP(H, a, b, c, d, x[13], 0x289b7ec6, 4) STEP(H, d, a, b, c, x[0], 0xeaa127fa, 11)
    STEP(H, c, d, a, b, x[3], 0xd4ef3085, 16) STEP(H, b, c, d, a, x[6], 0x04881d05, 23)
    STEP(H, a, b, c, d, x[9], 0xd9d4d039, 4) STEP(H, d, a, b, c, x[12], 0xe6db99e5, 11)
    STEP(H, c, d, a, b, x[15], 0x1fa27cf8, 16) STEP(H, b, c, d, a, x[2], 0xc4ac5665, 23)
    STEP(I, a, b, c, d, x[0], 0xf4292244, 6) STEP(I, d, a, b, c, x[7], 0x432aff97, 10)
    STEP(I, c, d, a, b, x[14], 0xab9423a7, 15) STEP(I, b, c, d, a, x[5], 0xfc93a039, 21)
    STEP(I, a, b, c, d, x[12], 0x655b59c3, 6) STEP(I, d, a, b, c, x[3], 0x8f0ccc92, 10)
    STEP(I, c, d, a, b, x[10], 0xffeff47d, 15) STEP(I, b, c, d, a, x[1], 0x85845dd1, 21)
    STEP(I, a, b, c, d, x[8], 0x6fa87e4f, 6) STEP(I, d, a, b, c, x[15], 0xfe2ce6e0, 10)
    STEP(I, c, d, a, b, x[6], 0xa3014314, 15) STEP(I, b, c, d, a, x[13], 0x4e0811a1, 21)
    STEP(I, a, b, c, d, x[4], 0xf7537e82, 6) STEP(I, d, a, b, c, x[11], 0xbd3af235, 10)
    STEP(I, c, d, a, b, x[2], 0x2ad7d2bb, 15) STEP(I, b, c, d, a, x[9], 0xeb86d391, 21)

    ctx->a += a; ctx->b += b; ctx->c += c; ctx->d += d;
}

static void md5_init(struct md5 *ctx)
{
    ctx->a = 0x67452301; ctx->b = 0xefcdab89; ctx->c = 0x98badcfe; ctx->d = 0x10325476;
    ctx->length = 0;
}

static void md5_update(struct md5 *ctx, const void *data, size_t size)
{
    const uint8_t *p = data;
    size_t used = ctx->length % 64;

    ctx->length += size;
    if (used)
    {
        size_t space = 64 - used;

        if (size < space)
        {
            memcpy(ctx->buffer + used, p, size);
            return;
        }
        memcpy(ctx->buffer + used, p, space);
        md5_block(ctx, ctx->buffer);
        p += space;
        size -= space;
    }
    while (size >= 64)
    {
        md5_block(ctx, p);
        p += 64;
        size -= 64;
    }
    memcpy(ctx->buffer, p, size);
}

/* Port of vkd3d's vkd3d_compute_dxbc_checksum (itself from RenderDoc). */
void sm2_dxbc_checksum(const void *dxbc, size_t size, uint32_t out[4])
{
    const uint8_t *data = (const uint8_t *)dxbc + 20;
    uint32_t block[16], num_bits, num_bits2, leftover, padding;
    size_t length = size - 20;
    struct md5 ctx;

    md5_init(&ctx);
    memset(block, 0, sizeof(block));
    num_bits = (uint32_t)(length * 8);
    num_bits2 = (num_bits >> 2) | 1;
    leftover = (uint32_t)(length % 64);
    md5_update(&ctx, data, length - leftover);
    data += length - leftover;

    if (leftover >= 56)
    {
        md5_update(&ctx, data, leftover);
        block[0] = 0x80;
        md5_update(&ctx, block, 64 - leftover);
        block[0] = num_bits;
        block[15] = num_bits2;
        md5_update(&ctx, block, 64);
    }
    else
    {
        md5_update(&ctx, &num_bits, sizeof(num_bits));
        if (leftover)
            md5_update(&ctx, data, leftover);
        padding = 64 - leftover - 4;
        block[0] = 0x80;
        memcpy((uint8_t *)block + padding - 4, &num_bits2, 4);
        md5_update(&ctx, block, padding);
    }
    out[0] = ctx.a;
    out[1] = ctx.b;
    out[2] = ctx.c;
    out[3] = ctx.d;
}

int sm2_dxbc_checksum_ok(const void *dxbc, size_t size)
{
    uint32_t sum[4];

    if (size <= 32 || memcmp(dxbc, "DXBC", 4))
        return 0;
    sm2_dxbc_checksum(dxbc, size, sum);
    return !memcmp(sum, (const uint8_t *)dxbc + 4, 16);
}

/* ---- root signature static samplers */

int sm2_filter_is_minmax(uint32_t filter)
{
    uint32_t reduction = (filter >> 7) & 3; /* 0 standard, 1 comparison, 2 minimum, 3 maximum */

    return reduction >= 2;
}

uint32_t sm2_filter_rewrite(uint32_t filter, enum sm2_minmax_rewrite mode)
{
    if (!sm2_filter_is_minmax(filter) || mode == SM2_MINMAX_KEEP)
        return filter;
    if (mode == SM2_MINMAX_POINT)
        return 0; /* D3D12_FILTER_MIN_MAG_MIP_POINT */
    return filter & ~(3u << 7);
}

static uint32_t rd32(const uint8_t *p)
{
    uint32_t v;

    memcpy(&v, p, 4);
    return v;
}

int sm2_rootsig_scan_samplers(void *blob, size_t size, enum sm2_minmax_rewrite mode,
        unsigned int *minmax, unsigned int *total, uint32_t *first_filter)
{
    uint8_t *base = blob, *rts0 = NULL;
    uint32_t part_count, i, rts0_size = 0, version, count, offset, stride;
    int changed = 0;

    *minmax = *total = 0;
    if (!blob || size < 32 || memcmp(base, "DXBC", 4))
        return -1;
    part_count = rd32(base + 28);
    if (part_count > 64 || 32 + (size_t)part_count * 4 > size)
        return -1;
    for (i = 0; i < part_count; i++)
    {
        uint32_t off = rd32(base + 32 + i * 4);

        if ((size_t)off + 8 > size)
            return -1;
        if (!memcmp(base + off, "RTS0", 4))
        {
            rts0 = base + off + 8;
            rts0_size = rd32(base + off + 4);
            if ((size_t)off + 8 + rts0_size > size)
                return -1;
            break;
        }
    }
    if (!rts0 || rts0_size < 24)
        return -1;

    version = rd32(rts0);         /* 1 = 1.0, 2 = 1.1, 3 = 1.2 */
    count = rd32(rts0 + 12);
    offset = rd32(rts0 + 16);
    if (version < 1 || version > 3)
        return -1;
    stride = version == 3 ? 14 * 4 : 13 * 4;
    if ((size_t)offset + (size_t)count * stride > rts0_size)
        return -1;

    *total = count;
    for (i = 0; i < count; i++)
    {
        uint8_t *sampler = rts0 + offset + i * stride;
        uint32_t filter = rd32(sampler), rewritten;

        if (!sm2_filter_is_minmax(filter))
            continue;
        if (!*minmax && first_filter)
            *first_filter = filter;
        (*minmax)++;
        rewritten = sm2_filter_rewrite(filter, mode);
        if (rewritten != filter)
        {
            memcpy(sampler, &rewritten, 4);
            changed = 1;
        }
    }
    if (changed)
    {
        uint32_t sum[4];

        sm2_dxbc_checksum(blob, size, sum);
        memcpy(base + 4, sum, 16);
    }
    return 0;
}
