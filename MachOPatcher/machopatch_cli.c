// machopatch - host CLI wrapper around MachOPatcher.
// usage: machopatch [-n install_name] [-r from=to]... [-s] in [out]
#include "MachOPatcher.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAX_REMAPS 64

/* Default redirections of macOS-only frameworks to the bundled shims. */
static const mp_dylib_remap kDefaultRemaps[] = {
    {"/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit", "@rpath/AppKit.framework/AppKit"},
    {"/System/Library/Frameworks/Cocoa.framework/Versions/A/Cocoa", "@rpath/AppKit.framework/AppKit"},
    {"/System/Library/Frameworks/Foundation.framework/Versions/C/Foundation",
     "/System/Library/Frameworks/Foundation.framework/Foundation"},
    {"/System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation",
     "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation"},
    {"/System/Library/Frameworks/QuartzCore.framework/Versions/A/QuartzCore",
     "/System/Library/Frameworks/QuartzCore.framework/QuartzCore"},
    {"/System/Library/Frameworks/CoreGraphics.framework/Versions/A/CoreGraphics",
     "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics"},
    {"/System/Library/Frameworks/Metal.framework/Versions/A/Metal",
     "/System/Library/Frameworks/Metal.framework/Metal"},
    {"/System/Library/Frameworks/CoreText.framework/Versions/A/CoreText",
     "/System/Library/Frameworks/CoreText.framework/CoreText"},
};

static void usage(void) {
    fprintf(stderr,
            "usage: machopatch [-n install_name] [-r from=to]... [-s] [-D] <in> [out]\n"
            "  -n  insert LC_ID_DYLIB with this install name if absent\n"
            "  -r  rewrite a dependent dylib path (repeatable)\n"
            "  -s  remove LC_CODE_SIGNATURE (re-sign afterwards)\n"
            "  -D  disable built-in macOS->iOS framework path remaps\n");
}

int main(int argc, char **argv) {
    mp_options opts;
    mp_default_options(&opts);
    mp_dylib_remap remaps[MAX_REMAPS];
    char *owned[MAX_REMAPS];
    size_t nremap = 0, nowned = 0;
    int use_defaults = 1;
    const char *in = NULL, *out = NULL;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-n") && i + 1 < argc) opts.install_name = argv[++i];
        else if (!strcmp(argv[i], "-s")) opts.strip_code_signature = 1;
        else if (!strcmp(argv[i], "-D")) use_defaults = 0;
        else if (!strcmp(argv[i], "-r") && i + 1 < argc) {
            char *dup = strdup(argv[++i]);
            char *eq = dup ? strchr(dup, '=') : NULL;
            if (!eq || nremap >= MAX_REMAPS) { free(dup); usage(); return 2; }
            *eq = 0;
            owned[nowned++] = dup;
            remaps[nremap].from = dup;
            remaps[nremap].to = eq + 1;
            nremap++;
        } else if (argv[i][0] == '-') { usage(); return 2; }
        else if (!in) in = argv[i];
        else if (!out) out = argv[i];
        else { usage(); return 2; }
    }
    if (!in) { usage(); return 2; }
    if (!out) out = in;
    if (use_defaults) {
        for (size_t k = 0; k < sizeof(kDefaultRemaps) / sizeof(kDefaultRemaps[0]) && nremap < MAX_REMAPS; k++)
            remaps[nremap++] = kDefaultRemaps[k];
    }
    opts.remaps = remaps;
    opts.remap_count = nremap;

    mp_report rep;
    memset(&rep, 0, sizeof(rep));
    mp_status st = mp_patch_file(in, out, &opts, &rep);
    for (size_t k = 0; k < nowned; k++) free(owned[k]);
    if (st != MP_OK) {
        fprintf(stderr, "machopatch: %s: %s\n", in, mp_strerror(st));
        return 1;
    }
    printf("machopatch: %s -> %s slices=%d filetype=%d pagezero=%d platform=%d remaps=%d "
           "id_dylib=%d sig_stripped=%d entryoff=0x%llx\n",
           in, out, rep.slices_patched, rep.converted_filetype, rep.pagezero_patched,
           rep.platform_patched, rep.remaps_applied, rep.id_dylib_inserted,
           rep.code_signature_stripped, (unsigned long long)rep.entryoff);
    return 0;
}
