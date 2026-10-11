// MachOPatcher.c - MH_EXECUTE -> MH_DYLIB conversion, __PAGEZERO relocation,
// platform rewrite, install-name remapping and LC_ID_DYLIB insertion.
//
// Adapted from the LiveContainer algorithm (LCMachOUtils.m, LCPatchExecSlice):
//  * filetype MH_EXECUTE -> MH_DYLIB so dyld accepts the image via dlopen().
//  * __PAGEZERO vmaddr=0xFFFFC000 vmsize=0x4000: a 4 GiB reservation at address
//    0 cannot be mapped inside a running process; one 16K page parked below
//    4 GiB keeps the segment table valid without colliding with the host.
// Thin arm64 Mach-O fields are little-endian; FAT headers are big-endian.
#include "MachOPatcher.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint32_t be32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3];
}
static uint64_t be64(const uint8_t *p) {
    return ((uint64_t)be32(p) << 32) | be32(p + 4);
}

void mp_default_options(mp_options *o) {
    memset(o, 0, sizeof(*o));
    o->ios_min_version = 0x000E0000; /* 14.0 */
    o->ios_sdk_version = 0x00110000; /* 17.0 */
}

const char *mp_strerror(mp_status s) {
    switch (s) {
    case MP_OK: return "ok";
    case MP_ERR_TRUNCATED: return "file truncated";
    case MP_ERR_BAD_MAGIC: return "not a 64-bit Mach-O / FAT image";
    case MP_ERR_NOT_ARM64: return "no arm64 slice";
    case MP_ERR_NOT_EXECUTE: return "filetype is neither MH_EXECUTE nor MH_DYLIB";
    case MP_ERR_MALFORMED: return "malformed load commands";
    case MP_ERR_NO_SPACE: return "no header padding to insert load command";
    case MP_ERR_REMAP_TOO_LONG: return "remapped dylib path does not fit in load command";
    case MP_ERR_IO: return "I/O error";
    }
    return "unknown error";
}

static int is_dylib_ref_cmd(uint32_t cmd) {
    return cmd == MP_LC_LOAD_DYLIB || cmd == MP_LC_LOAD_WEAK_DYLIB ||
           cmd == MP_LC_REEXPORT_DYLIB || cmd == MP_LC_LAZY_LOAD_DYLIB ||
           cmd == MP_LC_LOAD_UPWARD_DYLIB;
}

/* Validates the load-command table. Returns the lowest non-zero section file
 * offset (end of usable header padding) in *pad_end. */
static mp_status validate_cmds(const uint8_t *slice, size_t cap, uint64_t *pad_end) {
    const mp_mach_header_64 *h = (const mp_mach_header_64 *)slice;
    uint64_t end = sizeof(*h) + (uint64_t)h->sizeofcmds;
    if (end > cap) return MP_ERR_TRUNCATED;
    uint64_t lowest = cap;
    uint64_t off = sizeof(*h);
    for (uint32_t i = 0; i < h->ncmds; i++) {
        if (off + sizeof(mp_load_command) > end) return MP_ERR_MALFORMED;
        const mp_load_command *lc = (const mp_load_command *)(slice + off);
        if (lc->cmdsize < sizeof(mp_load_command) || (lc->cmdsize & 7) || off + lc->cmdsize > end)
            return MP_ERR_MALFORMED;
        if (lc->cmd == MP_LC_SEGMENT_64) {
            if (lc->cmdsize < sizeof(mp_segment_command_64)) return MP_ERR_MALFORMED;
            const mp_segment_command_64 *seg = (const mp_segment_command_64 *)lc;
            uint64_t need = sizeof(*seg) + (uint64_t)seg->nsects * sizeof(mp_section_64);
            if (need > lc->cmdsize) return MP_ERR_MALFORMED;
            const mp_section_64 *s = (const mp_section_64 *)(seg + 1);
            for (uint32_t k = 0; k < seg->nsects; k++)
                if (s[k].offset != 0 && s[k].offset < lowest) lowest = s[k].offset;
        }
        off += lc->cmdsize;
    }
    if (off != end) return MP_ERR_MALFORMED;
    if (pad_end) *pad_end = lowest;
    return MP_OK;
}

int mp_find_entryoff(const mp_mach_header_64 *h, size_t cap, uint64_t *entryoff) {
    if (!h || h->magic != MP_MH_MAGIC_64) return 0;
    const uint8_t *base = (const uint8_t *)h;
    uint64_t end = sizeof(*h) + (uint64_t)h->sizeofcmds;
    if (cap && end > cap) return 0;
    uint64_t off = sizeof(*h);
    for (uint32_t i = 0; i < h->ncmds && off + sizeof(mp_load_command) <= end; i++) {
        const mp_load_command *lc = (const mp_load_command *)(base + off);
        if (lc->cmdsize < sizeof(mp_load_command)) return 0;
        if (lc->cmd == MP_LC_MAIN && lc->cmdsize >= sizeof(mp_entry_point_command)) {
            *entryoff = ((const mp_entry_point_command *)lc)->entryoff;
            return 1;
        }
        off += lc->cmdsize;
    }
    return 0;
}

static mp_status apply_remap(uint8_t *cmdp, const mp_options *o, mp_report *rep) {
    mp_dylib_command *dc = (mp_dylib_command *)cmdp;
    if (dc->name_offset >= dc->cmdsize) return MP_ERR_MALFORMED;
    char *name = (char *)cmdp + dc->name_offset;
    size_t room = dc->cmdsize - dc->name_offset;
    if (!memchr(name, 0, room)) return MP_ERR_MALFORMED;
    for (size_t r = 0; r < o->remap_count; r++) {
        const mp_dylib_remap *m = &o->remaps[r];
        if (!m->from || !m->to || strcmp(name, m->from) != 0) continue;
        size_t n = strlen(m->to);
        if (n + 1 > room) return MP_ERR_REMAP_TOO_LONG;
        memset(name, 0, room);
        memcpy(name, m->to, n);
        rep->remaps_applied++;
        break;
    }
    return MP_OK;
}

static mp_status insert_id_dylib(uint8_t *slice, uint64_t pad_end, const char *install_name,
                                 mp_report *rep) {
    mp_mach_header_64 *h = (mp_mach_header_64 *)slice;
    size_t nlen = strlen(install_name) + 1;
    uint32_t size = (uint32_t)((sizeof(mp_dylib_command) + nlen + 7) & ~(size_t)7);
    uint64_t cur_end = sizeof(*h) + (uint64_t)h->sizeofcmds;
    if (cur_end + size > pad_end) return MP_ERR_NO_SPACE;
    uint8_t *p = slice + cur_end;
    for (uint32_t i = 0; i < size; i++)
        if (p[i] != 0) return MP_ERR_NO_SPACE; /* padding must be unused */
    memset(p, 0, size);
    mp_dylib_command *dc = (mp_dylib_command *)p;
    dc->cmd = MP_LC_ID_DYLIB;
    dc->cmdsize = size;
    dc->name_offset = sizeof(mp_dylib_command);
    dc->timestamp = 2;
    dc->current_version = 0x00010000;
    dc->compatibility_version = 0x00010000;
    memcpy(p + sizeof(mp_dylib_command), install_name, nlen);
    h->ncmds += 1;
    h->sizeofcmds += size;
    rep->id_dylib_inserted = 1;
    return MP_OK;
}

static void remove_cmd(uint8_t *slice, uint64_t off, uint32_t size) {
    mp_mach_header_64 *h = (mp_mach_header_64 *)slice;
    uint64_t end = sizeof(*h) + (uint64_t)h->sizeofcmds;
    memmove(slice + off, slice + off + size, (size_t)(end - off - size));
    memset(slice + end - size, 0, size);
    h->ncmds -= 1;
    h->sizeofcmds -= size;
}

mp_status mp_patch_slice(uint8_t *slice, size_t cap, const mp_options *o, mp_report *rep) {
    if (cap < sizeof(mp_mach_header_64)) return MP_ERR_TRUNCATED;
    mp_mach_header_64 *h = (mp_mach_header_64 *)slice;
    if (h->magic != MP_MH_MAGIC_64) return MP_ERR_BAD_MAGIC;
    if (h->cputype != MP_CPU_TYPE_ARM64) return MP_ERR_NOT_ARM64;
    if (h->filetype != MP_MH_EXECUTE && h->filetype != MP_MH_DYLIB) return MP_ERR_NOT_EXECUTE;

    uint64_t pad_end = 0;
    mp_status st = validate_cmds(slice, cap, &pad_end);
    if (st != MP_OK) return st;

    if (h->filetype == MP_MH_EXECUTE) {
        h->filetype = MP_MH_DYLIB;
        rep->converted_filetype = 1;
    }

    int has_id = 0;
    uint64_t sig_off = 0;
    uint32_t sig_size = 0;
    uint64_t off = sizeof(*h);
    for (uint32_t i = 0; i < h->ncmds; i++) {
        mp_load_command *lc = (mp_load_command *)(slice + off);
        switch (lc->cmd) {
        case MP_LC_SEGMENT_64: {
            mp_segment_command_64 *seg = (mp_segment_command_64 *)lc;
            if (strncmp(seg->segname, "__PAGEZERO", 16) == 0) {
                seg->vmaddr = MP_PAGEZERO_NEW_VMADDR;
                seg->vmsize = MP_PAGEZERO_NEW_VMSIZE;
                rep->pagezero_patched = 1;
            }
            break;
        }
        case MP_LC_BUILD_VERSION: {
            mp_build_version_command *bv = (mp_build_version_command *)lc;
            if (lc->cmdsize < sizeof(*bv)) return MP_ERR_MALFORMED;
            if (bv->platform != MP_PLATFORM_IOS) {
                bv->platform = MP_PLATFORM_IOS;
                bv->minos = o->ios_min_version;
                bv->sdk = o->ios_sdk_version;
                rep->platform_patched = 1;
            }
            break;
        }
        case MP_LC_VERSION_MIN_MACOSX: {
            mp_version_min_command *vm = (mp_version_min_command *)lc;
            if (lc->cmdsize < sizeof(*vm)) return MP_ERR_MALFORMED;
            vm->cmd = MP_LC_VERSION_MIN_IPHONEOS;
            vm->version = o->ios_min_version;
            vm->sdk = o->ios_sdk_version;
            rep->platform_patched = 1;
            break;
        }
        case MP_LC_MAIN:
            if (lc->cmdsize >= sizeof(mp_entry_point_command))
                rep->entryoff = ((mp_entry_point_command *)lc)->entryoff;
            break;
        case MP_LC_ID_DYLIB:
            has_id = 1;
            break;
        case MP_LC_CODE_SIGNATURE:
            sig_off = off;
            sig_size = lc->cmdsize;
            break;
        default:
            if (is_dylib_ref_cmd(lc->cmd)) {
                if (lc->cmdsize < sizeof(mp_dylib_command)) return MP_ERR_MALFORMED;
                st = apply_remap((uint8_t *)lc, o, rep);
                if (st != MP_OK) return st;
            }
            break;
        }
        off += lc->cmdsize;
    }

    if (o->strip_code_signature && sig_size) {
        remove_cmd(slice, sig_off, sig_size);
        rep->code_signature_stripped = 1;
    }
    if (!has_id && o->install_name) {
        st = insert_id_dylib(slice, pad_end, o->install_name, rep);
        if (st != MP_OK) return st;
    }
    rep->slices_patched++;
    return MP_OK;
}

mp_status mp_patch_buffer(uint8_t *buf, size_t len, const mp_options *o, mp_report *rep) {
    if (len < 8) return MP_ERR_TRUNCATED;
    uint32_t magic_be = be32(buf);
    if (magic_be != MP_FAT_MAGIC && magic_be != MP_FAT_MAGIC_64)
        return mp_patch_slice(buf, len, o, rep);

    int is64 = magic_be == MP_FAT_MAGIC_64;
    uint32_t n = be32(buf + 4);
    size_t esz = is64 ? 32 : 20;
    if (n == 0 || n > 64 || 8 + (uint64_t)n * esz > len) return MP_ERR_MALFORMED;
    int found = 0;
    for (uint32_t i = 0; i < n; i++) {
        const uint8_t *a = buf + 8 + i * esz;
        uint32_t cpu = be32(a);
        uint64_t so = is64 ? be64(a + 8) : be32(a + 8);
        uint64_t ss = is64 ? be64(a + 16) : be32(a + 12);
        if (cpu != MP_CPU_TYPE_ARM64) continue;
        if (so > len || ss > len - so) return MP_ERR_TRUNCATED;
        mp_status st = mp_patch_slice(buf + so, (size_t)ss, o, rep);
        if (st != MP_OK) return st;
        found = 1;
    }
    return found ? MP_OK : MP_ERR_NOT_ARM64;
}

mp_status mp_patch_file(const char *in_path, const char *out_path, const mp_options *o,
                        mp_report *rep) {
    FILE *f = fopen(in_path, "rb");
    if (!f) return MP_ERR_IO;
    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return MP_ERR_IO; }
    long sz = ftell(f);
    if (sz <= 0 || fseek(f, 0, SEEK_SET) != 0) { fclose(f); return MP_ERR_IO; }
    uint8_t *buf = (uint8_t *)malloc((size_t)sz);
    if (!buf) { fclose(f); return MP_ERR_IO; }
    size_t got = fread(buf, 1, (size_t)sz, f);
    fclose(f);
    if (got != (size_t)sz) { free(buf); return MP_ERR_IO; }

    mp_status st = mp_patch_buffer(buf, (size_t)sz, o, rep);
    if (st == MP_OK) {
        f = fopen(out_path, "wb");
        if (!f) st = MP_ERR_IO;
        else {
            if (fwrite(buf, 1, (size_t)sz, f) != (size_t)sz) st = MP_ERR_IO;
            if (fclose(f) != 0) st = MP_ERR_IO;
        }
    }
    free(buf);
    return st;
}
