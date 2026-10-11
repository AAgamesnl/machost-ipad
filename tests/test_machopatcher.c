// Unit tests for MachOPatcher. Builds a synthetic arm64 MH_EXECUTE in memory.
// cc -std=c11 -IMachOPatcher tests/test_machopatcher.c MachOPatcher/MachOPatcher.c
#include "MachOPatcher.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures = 0;
#define CHECK(c) do { if (!(c)) { fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #c); failures++; } } while (0)

#define IMG_SIZE 0x8000u
#define SECT_OFF 0x1000u
static const char *kAppKit = "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit";

typedef struct { uint8_t *buf; uint32_t off; } builder;
static void *put(builder *b, uint32_t size) { void *p = b->buf + b->off; b->off += size; return p; }

static uint8_t *make_exec(int with_sig, uint32_t platform) {
    uint8_t *buf = calloc(1, IMG_SIZE);
    builder b = {buf, 0};
    mp_mach_header_64 *h = put(&b, sizeof(*h));
    h->magic = MP_MH_MAGIC_64;
    h->cputype = MP_CPU_TYPE_ARM64;
    h->filetype = MP_MH_EXECUTE;

    mp_segment_command_64 *pz = put(&b, sizeof(*pz));
    pz->cmd = MP_LC_SEGMENT_64; pz->cmdsize = sizeof(*pz);
    memcpy(pz->segname, "__PAGEZERO", 10);
    pz->vmsize = 0x100000000ull;

    mp_segment_command_64 *tx = put(&b, sizeof(*tx));
    tx->cmd = MP_LC_SEGMENT_64; tx->cmdsize = sizeof(*tx) + sizeof(mp_section_64);
    memcpy(tx->segname, "__TEXT", 6);
    tx->vmaddr = 0x100000000ull; tx->vmsize = IMG_SIZE; tx->filesize = IMG_SIZE; tx->nsects = 1;
    mp_section_64 *s = put(&b, sizeof(*s));
    memcpy(s->sectname, "__text", 6); memcpy(s->segname, "__TEXT", 6);
    s->offset = SECT_OFF; s->size = 4;

    mp_build_version_command *bv = put(&b, sizeof(*bv));
    bv->cmd = MP_LC_BUILD_VERSION; bv->cmdsize = sizeof(*bv);
    bv->platform = platform; bv->minos = 0x000B0000;

    mp_entry_point_command *ep = put(&b, sizeof(*ep));
    ep->cmd = MP_LC_MAIN; ep->cmdsize = sizeof(*ep); ep->entryoff = SECT_OFF;

    uint32_t dsz = (uint32_t)((sizeof(mp_dylib_command) + strlen(kAppKit) + 1 + 7) & ~7u);
    mp_dylib_command *dc = put(&b, dsz);
    dc->cmd = MP_LC_LOAD_DYLIB; dc->cmdsize = dsz; dc->name_offset = sizeof(*dc);
    memcpy((char *)dc + sizeof(*dc), kAppKit, strlen(kAppKit));

    uint32_t n = 6;
    if (with_sig) {
        mp_load_command *cs = put(&b, 16);
        cs->cmd = MP_LC_CODE_SIGNATURE; cs->cmdsize = 16;
        n++;
    }
    h->ncmds = n;
    h->sizeofcmds = b.off - (uint32_t)sizeof(*h);
    return buf;
}

static const mp_segment_command_64 *find_seg(const uint8_t *buf, const char *name) {
    const mp_mach_header_64 *h = (const void *)buf;
    uint32_t off = sizeof(*h);
    for (uint32_t i = 0; i < h->ncmds; i++) {
        const mp_load_command *lc = (const void *)(buf + off);
        if (lc->cmd == MP_LC_SEGMENT_64 && !strncmp(((const mp_segment_command_64 *)lc)->segname, name, 16))
            return (const void *)lc;
        off += lc->cmdsize;
    }
    return NULL;
}

static const mp_load_command *find_cmd(const uint8_t *buf, uint32_t cmd) {
    const mp_mach_header_64 *h = (const void *)buf;
    uint32_t off = sizeof(*h);
    for (uint32_t i = 0; i < h->ncmds; i++) {
        const mp_load_command *lc = (const void *)(buf + off);
        if (lc->cmd == cmd) return lc;
        off += lc->cmdsize;
    }
    return NULL;
}

static void test_basic(void) {
    uint8_t *buf = make_exec(1, MP_PLATFORM_MACOS);
    mp_dylib_remap rm[] = {{kAppKit, "@rpath/AppKit.framework/AppKit"}};
    mp_options o; mp_default_options(&o);
    o.remaps = rm; o.remap_count = 1;
    o.install_name = "@rpath/Guest.dylib";
    mp_report r; memset(&r, 0, sizeof(r));
    CHECK(mp_patch_buffer(buf, IMG_SIZE, &o, &r) == MP_OK);
    const mp_mach_header_64 *h = (const void *)buf;
    CHECK(h->filetype == MP_MH_DYLIB);
    const mp_segment_command_64 *pz = find_seg(buf, "__PAGEZERO");
    CHECK(pz && pz->vmaddr == 0xFFFFC000ull && pz->vmsize == 0x4000ull);
    const mp_build_version_command *bv = (const void *)find_cmd(buf, MP_LC_BUILD_VERSION);
    CHECK(bv && bv->platform == MP_PLATFORM_IOS && bv->minos == 0x000E0000);
    const mp_dylib_command *dc = (const void *)find_cmd(buf, MP_LC_LOAD_DYLIB);
    CHECK(dc && !strcmp((const char *)dc + dc->name_offset, "@rpath/AppKit.framework/AppKit"));
    const mp_dylib_command *id = (const void *)find_cmd(buf, MP_LC_ID_DYLIB);
    CHECK(id && !strcmp((const char *)id + id->name_offset, "@rpath/Guest.dylib"));
    CHECK(find_cmd(buf, MP_LC_CODE_SIGNATURE) != NULL); /* not stripped by default */
    CHECK(r.entryoff == SECT_OFF && r.slices_patched == 1 && r.remaps_applied == 1);
    uint64_t e = 0;
    CHECK(mp_find_entryoff(h, IMG_SIZE, &e) && e == SECT_OFF);

    /* Idempotence: second pass must succeed and not insert a second ID. */
    uint32_t ncmds = h->ncmds;
    memset(&r, 0, sizeof(r));
    CHECK(mp_patch_buffer(buf, IMG_SIZE, &o, &r) == MP_OK);
    CHECK(h->ncmds == ncmds && !r.id_dylib_inserted && !r.converted_filetype);
    free(buf);
}

static void test_strip_signature(void) {
    uint8_t *buf = make_exec(1, MP_PLATFORM_MACOS);
    mp_options o; mp_default_options(&o);
    o.strip_code_signature = 1;
    mp_report r; memset(&r, 0, sizeof(r));
    uint32_t before = ((mp_mach_header_64 *)buf)->ncmds;
    CHECK(mp_patch_buffer(buf, IMG_SIZE, &o, &r) == MP_OK);
    CHECK(find_cmd(buf, MP_LC_CODE_SIGNATURE) == NULL);
    CHECK(((mp_mach_header_64 *)buf)->ncmds == before - 1);
    CHECK(find_cmd(buf, MP_LC_MAIN) != NULL);
    free(buf);
}

static void test_errors(void) {
    uint8_t *buf = make_exec(0, MP_PLATFORM_MACOS);
    mp_options o; mp_default_options(&o);
    mp_report r; memset(&r, 0, sizeof(r));

    CHECK(mp_patch_buffer(buf, 4, &o, &r) == MP_ERR_TRUNCATED);
    CHECK(mp_patch_buffer(buf, 40, &o, &r) == MP_ERR_TRUNCATED); /* sizeofcmds > cap */

    mp_dylib_remap big[] = {{kAppKit, "@rpath/A/very/long/path/that/certainly/does/not/fit/inside/the/existing/command/xxxxxxxxxxxxxxxxxxxx"}};
    o.remaps = big; o.remap_count = 1;
    CHECK(mp_patch_buffer(buf, IMG_SIZE, &o, &r) == MP_ERR_REMAP_TOO_LONG);
    free(buf);

    buf = make_exec(0, MP_PLATFORM_MACOS);
    mp_default_options(&o);
    char longname[SECT_OFF];
    memset(longname, 'a', sizeof(longname) - 1); longname[sizeof(longname) - 1] = 0;
    o.install_name = longname;
    CHECK(mp_patch_buffer(buf, IMG_SIZE, &o, &r) == MP_ERR_NO_SPACE);
    free(buf);

    buf = make_exec(0, MP_PLATFORM_MACOS);
    mp_default_options(&o);
    ((mp_mach_header_64 *)buf)->cputype = 0x01000007; /* x86_64 */
    CHECK(mp_patch_buffer(buf, IMG_SIZE, &o, &r) == MP_ERR_NOT_ARM64);
    ((mp_mach_header_64 *)buf)->cputype = MP_CPU_TYPE_ARM64;
    ((mp_mach_header_64 *)buf)->filetype = 0x8; /* MH_BUNDLE */
    CHECK(mp_patch_buffer(buf, IMG_SIZE, &o, &r) == MP_ERR_NOT_EXECUTE);
    ((mp_mach_header_64 *)buf)->filetype = MP_MH_EXECUTE;
    ((mp_load_command *)(buf + sizeof(mp_mach_header_64)))->cmdsize = 3;
    CHECK(mp_patch_buffer(buf, IMG_SIZE, &o, &r) == MP_ERR_MALFORMED);
    ((mp_mach_header_64 *)buf)->magic = 0;
    CHECK(mp_patch_buffer(buf, IMG_SIZE, &o, &r) == MP_ERR_BAD_MAGIC);
    free(buf);
}

static void wbe32(uint8_t *p, uint32_t v) { p[0] = v >> 24; p[1] = v >> 16; p[2] = v >> 8; p[3] = v; }

static void test_fat(void) {
    size_t total = 0x4000 + IMG_SIZE;
    uint8_t *fat = calloc(1, total);
    uint8_t *thin = make_exec(0, MP_PLATFORM_MACOS);
    memcpy(fat + 0x4000, thin, IMG_SIZE);
    free(thin);
    wbe32(fat, MP_FAT_MAGIC); wbe32(fat + 4, 2);
    wbe32(fat + 8, 0x01000007); wbe32(fat + 16, 0x100); wbe32(fat + 20, 0x100); /* x86 dummy */
    wbe32(fat + 28, MP_CPU_TYPE_ARM64); wbe32(fat + 36, 0x4000); wbe32(fat + 40, IMG_SIZE);
    mp_options o; mp_default_options(&o);
    mp_report r; memset(&r, 0, sizeof(r));
    CHECK(mp_patch_buffer(fat, total, &o, &r) == MP_OK);
    CHECK(r.slices_patched == 1);
    CHECK(((mp_mach_header_64 *)(fat + 0x4000))->filetype == MP_MH_DYLIB);
    wbe32(fat + 40, (uint32_t)total); /* slice overruns file */
    CHECK(mp_patch_buffer(fat, total, &o, &r) == MP_ERR_TRUNCATED);
    free(fat);
}

int main(void) {
    test_basic();
    test_strip_signature();
    test_errors();
    test_fat();
    if (failures) { fprintf(stderr, "%d failure(s)\n", failures); return 1; }
    printf("all MachOPatcher tests passed\n");
    return 0;
}
