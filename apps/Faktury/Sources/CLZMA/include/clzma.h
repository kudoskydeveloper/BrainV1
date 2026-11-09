// The few liblzma declarations PAY by square needs. liblzma ships with macOS (liblzma.tbd in the SDK) but without headers.
// Layouts match xz-utils 5.x (lzma/base.h, lzma/filter.h, lzma/lzma12.h).
#pragma once
#include <stdint.h>
#include <stddef.h>

typedef uint64_t clzma_vli;

typedef struct {
    uint32_t dict_size;
    const uint8_t *preset_dict;
    uint32_t preset_dict_size;
    uint32_t lc;
    uint32_t lp;
    uint32_t pb;
    int mode;
    uint32_t nice_len;
    int mf;
    uint32_t depth;
    uint32_t ext_flags;
    uint32_t ext_size_low;
    uint32_t ext_size_high;
    uint32_t reserved_int4;
    int reserved_enum1, reserved_enum2, reserved_enum3, reserved_enum4;
    void *reserved_ptr1;
    void *reserved_ptr2;
    uint8_t padding[64];   // room in case a newer liblzma grows the struct
} clzma_options_lzma;

typedef struct {
    clzma_vli id;
    void *options;
} clzma_filter;

#define CLZMA_FILTER_LZMA1 0x4000000000000001ULL
#define CLZMA_VLI_UNKNOWN UINT64_MAX

unsigned char lzma_lzma_preset(clzma_options_lzma *options, uint32_t preset);
int lzma_raw_buffer_encode(const clzma_filter *filters, const void *allocator, const uint8_t *in, size_t in_size,
                           uint8_t *out, size_t *out_pos, size_t out_size);
int lzma_raw_buffer_decode(const clzma_filter *filters, const void *allocator, const uint8_t *in, size_t *in_pos, size_t in_size,
                           uint8_t *out, size_t *out_pos, size_t out_size);

/// Raw LZMA1 with PAY by square's parameters (lc=3, lp=0, pb=2, dictionary 128 KiB). Returns 0 on success.
static inline int clzma_bysquare_encode(const uint8_t *in, size_t in_size, uint8_t *out, size_t *out_pos, size_t out_size) {
    clzma_options_lzma opt = {0};
    if (lzma_lzma_preset(&opt, 6)) return -1;
    opt.dict_size = 1u << 17; opt.lc = 3; opt.lp = 0; opt.pb = 2;
    clzma_filter filters[2] = {{CLZMA_FILTER_LZMA1, &opt}, {CLZMA_VLI_UNKNOWN, NULL}};
    return lzma_raw_buffer_encode(filters, NULL, in, in_size, out, out_pos, out_size);
}

/// The reverse, for tests. Returns 0 on success (or 1, LZMA_STREAM_END).
static inline int clzma_bysquare_decode(const uint8_t *in, size_t in_size, uint8_t *out, size_t *out_pos, size_t out_size) {
    clzma_options_lzma opt = {0};
    if (lzma_lzma_preset(&opt, 6)) return -1;
    opt.dict_size = 1u << 17; opt.lc = 3; opt.lp = 0; opt.pb = 2;
    clzma_filter filters[2] = {{CLZMA_FILTER_LZMA1, &opt}, {CLZMA_VLI_UNKNOWN, NULL}};
    size_t in_pos = 0;
    return lzma_raw_buffer_decode(filters, NULL, in, &in_pos, in_size, out, out_pos, out_size);
}
