/* DXBC container helpers: checksum (needed after editing a blob) and root-signature
 * static-sampler scanning. Platform independent, unit-tested in ../tests. */
#ifndef SM2FIX_DXBC_H
#define SM2FIX_DXBC_H

#include <stddef.h>
#include <stdint.h>

/* The DXBC checksum (MD5 variant) stored at bytes 4..19 of every container. */
void sm2_dxbc_checksum(const void *dxbc, size_t size, uint32_t out[4]);
/* Returns 1 if the stored checksum matches the contents. */
int sm2_dxbc_checksum_ok(const void *dxbc, size_t size);

enum sm2_minmax_rewrite
{
    SM2_MINMAX_KEEP = 0,    /* only count */
    SM2_MINMAX_LINEAR,      /* drop the min/max reduction, keep the filtering */
    SM2_MINMAX_POINT,       /* drop the reduction and use point sampling */
};

/* D3D12_FILTER values whose reduction type is MINIMUM or MAXIMUM (an Apple10-only
 * Metal feature). */
int sm2_filter_is_minmax(uint32_t filter);
uint32_t sm2_filter_rewrite(uint32_t filter, enum sm2_minmax_rewrite mode);

/* Scans the static samplers of a serialized root signature (DXBC container with an
 * RTS0 part). Counts min/max samplers into *minmax and *total. With a rewrite mode,
 * patches them in place and fixes the container checksum. Returns 0 on success,
 * -1 if the blob isn't a root signature we understand. */
int sm2_rootsig_scan_samplers(void *blob, size_t size, enum sm2_minmax_rewrite mode,
        unsigned int *minmax, unsigned int *total, uint32_t *first_filter);

#endif
