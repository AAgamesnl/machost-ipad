// MachOPatcher.h - portable Mach-O MH_EXECUTE -> MH_DYLIB transformer.
// Self-contained struct definitions so it builds on macOS, iOS, Linux and
// Windows hosts (build-time patching + unit tests) as well as on-device.
#ifndef MACHOPATCHER_H
#define MACHOPATCHER_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define MP_MH_MAGIC_64      0xFEEDFACFu
#define MP_FAT_MAGIC        0xCAFEBABEu
#define MP_FAT_MAGIC_64     0xCAFEBABFu
#define MP_CPU_TYPE_ARM64   0x0100000Cu
#define MP_MH_EXECUTE       0x2u
#define MP_MH_DYLIB         0x6u

#define MP_LC_REQ_DYLD              0x80000000u
#define MP_LC_SEGMENT_64            0x19u
#define MP_LC_LOAD_DYLIB            0x0Cu
#define MP_LC_ID_DYLIB              0x0Du
#define MP_LC_LOAD_DYLINKER         0x0Eu
#define MP_LC_CODE_SIGNATURE        0x1Du
#define MP_LC_LAZY_LOAD_DYLIB       0x20u
#define MP_LC_VERSION_MIN_MACOSX    0x24u
#define MP_LC_VERSION_MIN_IPHONEOS  0x25u
#define MP_LC_BUILD_VERSION         0x32u
#define MP_LC_LOAD_WEAK_DYLIB       (0x18u | MP_LC_REQ_DYLD)
#define MP_LC_REEXPORT_DYLIB        (0x1Fu | MP_LC_REQ_DYLD)
#define MP_LC_LOAD_UPWARD_DYLIB     (0x23u | MP_LC_REQ_DYLD)
#define MP_LC_MAIN                  (0x28u | MP_LC_REQ_DYLD)

#define MP_PLATFORM_MACOS       1u
#define MP_PLATFORM_IOS         2u

/* LiveContainer PAGEZERO relocation values. */
#define MP_PAGEZERO_NEW_VMADDR  0xFFFFC000ull
#define MP_PAGEZERO_NEW_VMSIZE  0x4000ull

typedef struct {
    uint32_t magic, cputype, cpusubtype, filetype, ncmds, sizeofcmds, flags, reserved;
} mp_mach_header_64;

typedef struct { uint32_t cmd, cmdsize; } mp_load_command;

typedef struct {
    uint32_t cmd, cmdsize;
    char     segname[16];
    uint64_t vmaddr, vmsize, fileoff, filesize;
    uint32_t maxprot, initprot, nsects, flags;
} mp_segment_command_64;

typedef struct {
    char     sectname[16], segname[16];
    uint64_t addr, size;
    uint32_t offset, align, reloff, nreloc, flags, reserved1, reserved2, reserved3;
} mp_section_64;

typedef struct {
    uint32_t cmd, cmdsize;
    uint32_t name_offset, timestamp, current_version, compatibility_version;
} mp_dylib_command;

typedef struct { uint32_t cmd, cmdsize; uint64_t entryoff, stacksize; } mp_entry_point_command;
typedef struct { uint32_t cmd, cmdsize, platform, minos, sdk, ntools; } mp_build_version_command;
typedef struct { uint32_t cmd, cmdsize, version, sdk; } mp_version_min_command;

/* One install-name rewrite rule: any LC_*_DYLIB whose path equals `from`
 * is rewritten to `to` (used to redirect AppKit -> AppKitShim etc.). */
typedef struct { const char *from; const char *to; } mp_dylib_remap;

typedef struct {
    uint32_t ios_min_version;        /* packed X.Y.Z (e.g. 0x000E0000 = 14.0) */
    uint32_t ios_sdk_version;
    const char *install_name;        /* LC_ID_DYLIB to insert if absent; NULL = skip */
    const mp_dylib_remap *remaps;
    size_t   remap_count;
    int      strip_code_signature;   /* 1 = zero LC_CODE_SIGNATURE (re-sign later) */
} mp_options;

typedef struct {
    int      converted_filetype;
    int      pagezero_patched;
    int      platform_patched;
    int      id_dylib_inserted;
    int      remaps_applied;
    int      code_signature_stripped;
    int      slices_patched;
    uint64_t entryoff;               /* from LC_MAIN, 0 if none */
} mp_report;

typedef enum {
    MP_OK = 0,
    MP_ERR_TRUNCATED = -1,
    MP_ERR_BAD_MAGIC = -2,
    MP_ERR_NOT_ARM64 = -3,
    MP_ERR_NOT_EXECUTE = -4,
    MP_ERR_MALFORMED = -5,
    MP_ERR_NO_SPACE = -6,
    MP_ERR_REMAP_TOO_LONG = -7,
    MP_ERR_IO = -8,
} mp_status;

void        mp_default_options(mp_options *opts);
const char *mp_strerror(mp_status s);

/* Patch a thin arm64 slice in place. `cap` is the slice size in bytes. */
mp_status mp_patch_slice(uint8_t *slice, size_t cap, const mp_options *opts, mp_report *rep);

/* Patch a thin or FAT image in place (only arm64 slices are touched). */
mp_status mp_patch_buffer(uint8_t *buf, size_t len, const mp_options *opts, mp_report *rep);

/* Convenience: read file, patch, write to out_path (may equal in_path). */
mp_status mp_patch_file(const char *in_path, const char *out_path,
                        const mp_options *opts, mp_report *rep);

/* Read LC_MAIN entryoff of an (already loaded or on-disk) arm64 header. */
int mp_find_entryoff(const mp_mach_header_64 *hdr, size_t cap, uint64_t *entryoff);

#ifdef __cplusplus
}
#endif
#endif
