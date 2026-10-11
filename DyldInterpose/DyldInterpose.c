// DyldInterpose.c - Interposing and redirection mechanisms for _NSGetExecutablePath,
// @executable_path, exit handling, and dynamic symbol rebinding for guest macOS binaries.

#include "DyldInterpose.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(__APPLE__)
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <mach/mach.h>
#include <mach/mach_init.h>
#include <mach/vm_page_size.h>
#include <sys/mman.h>
#include <pthread.h>
#include <dlfcn.h>
#include <unistd.h>
#else
// Portability stubs for non-Darwin host compilation and testing
#include <stdint.h>
#endif

#define MAX_PATH_LEN 1024
#define MAX_REBINDINGS 128

static char s_guest_path[MAX_PATH_LEN] = {0};
static int s_has_guest_path = 0;
static void (*s_exit_callback)(int status) = NULL;

#if defined(__APPLE__)
static pthread_mutex_t s_rebind_lock = PTHREAD_MUTEX_INITIALIZER;

typedef struct {
    char name[128];
    void *replacement;
    void **original;
} RebindRule;

static RebindRule s_rebindings[MAX_REBINDINGS];
static size_t s_rebind_count = 0;
static int s_listener_registered = 0;

static int (*s_orig_NSGetExecutablePath)(char *buf, uint32_t *bufsize) = NULL;
static int (*s_orig_proc_pidpath)(int pid, void *buffer, uint32_t buffersize) = NULL;
static void (*s_orig_exit)(int status) = NULL;
static void (*s_orig__exit)(int status) = NULL;

static inline vm_size_t di_get_page_size(void) {
    if (vm_page_size > 0) return vm_page_size;
    long sz = sysconf(_SC_PAGESIZE);
    return (sz > 0) ? (vm_size_t)sz : 16384;
}

/* Interposed _NSGetExecutablePath returning the guest path */
static int interposed_NSGetExecutablePath(char *buf, uint32_t *bufsize) {
    if (!buf || !bufsize) return -1;
    if (s_has_guest_path) {
        size_t len = strlen(s_guest_path);
        if (*bufsize < (uint32_t)(len + 1)) {
            *bufsize = (uint32_t)(len + 1);
            return -1;
        }
        memcpy(buf, s_guest_path, len + 1);
        return 0;
    }
    if (s_orig_NSGetExecutablePath) {
        return s_orig_NSGetExecutablePath(buf, bufsize);
    }
    return -1;
}

/* Interposed proc_pidpath returning guest path for current pid */
static int interposed_proc_pidpath(int pid, void *buffer, uint32_t buffersize) {
    if (s_has_guest_path && (pid == getpid() || pid == 0)) {
        size_t len = strlen(s_guest_path);
        if (buffersize < len + 1) return 0;
        memcpy(buffer, s_guest_path, len + 1);
        return (int)len;
    }
    if (s_orig_proc_pidpath) {
        return s_orig_proc_pidpath(pid, buffer, buffersize);
    }
    return 0;
}

/* Interposed exit and _exit to prevent guest binary from killing the host app */
static void interposed_exit(int status) {
    if (s_exit_callback) {
        s_exit_callback(status);
    }
    pthread_exit(NULL);
}

static void interposed__exit(int status) {
    if (s_exit_callback) {
        s_exit_callback(status);
    }
    pthread_exit(NULL);
}

/* Dyld interpose tuple placed into __DATA,__interpose section */
struct dyld_interpose_tuple {
    const void *replacement;
    const void *replacee;
};

__attribute__((used)) static const struct dyld_interpose_tuple s_interpose_tuples[]
__attribute__((section("__DATA,__interpose"))) = {
    { (const void *)&interposed_NSGetExecutablePath, (const void *)&_NSGetExecutablePath },
    { (const void *)&interposed_exit, (const void *)&exit },
    { (const void *)&interposed__exit, (const void *)&_exit }
};

/* Matches symbol names with or without leading underscore */
static int symbol_matches(const char *symbol_in_table, const char *target) {
    if (!symbol_in_table || !target) return 0;
    if (strcmp(symbol_in_table, target) == 0) return 1;
    if (symbol_in_table[0] == '_' && strcmp(symbol_in_table + 1, target) == 0) return 1;
    if (target[0] == '_' && strcmp(symbol_in_table, target + 1) == 0) return 1;
    return 0;
}

/* Helper to rewrite symbol pointers in a section */
static int rebind_section(const struct mach_header_64 *header,
                          intptr_t slide,
                          uintptr_t linkedit_base,
                          const struct symtab_command *symtab,
                          const struct dysymtab_command *dysymtab,
                          const struct section_64 *sect) {
    (void)header;
    if (!sect || sect->size == 0) return 0;

    void **indirect_symbol_bindings = (void **)(slide + sect->addr);
    const uint32_t *indirect_symbol_indices = (const uint32_t *)(linkedit_base + dysymtab->indirectsymoff);
    const struct nlist_64 *symbols = (const struct nlist_64 *)(linkedit_base + symtab->symoff);
    const char *strings = (const char *)(linkedit_base + symtab->stroff);

    uint32_t indirect_index = sect->reserved1;
    size_t count = sect->size / sizeof(void *);
    int rewritten = 0;

    for (size_t i = 0; i < count; i++) {
        uint32_t sym_index = indirect_symbol_indices[indirect_index + i];
        if (sym_index == INDIRECT_SYMBOL_LOCAL || sym_index == INDIRECT_SYMBOL_ABS ||
            sym_index == (INDIRECT_SYMBOL_LOCAL | INDIRECT_SYMBOL_ABS)) {
            continue;
        }

        if (sym_index >= symtab->nsyms) continue;

        uint32_t str_index = symbols[sym_index].n_un.n_strx;
        if (str_index == 0 || str_index >= symtab->strsize) continue;
        const char *sym_name = strings + str_index;

        for (size_t r = 0; r < s_rebind_count; r++) {
            if (symbol_matches(sym_name, s_rebindings[r].name)) {
                // Prevent infinite recursion loops if already rebound
                if (s_rebindings[r].original && *(s_rebindings[r].original) == NULL &&
                    indirect_symbol_bindings[i] != s_rebindings[r].replacement) {
                    *(s_rebindings[r].original) = indirect_symbol_bindings[i];
                }

                if (indirect_symbol_bindings[i] != s_rebindings[r].replacement) {
                    // Make page writable using dynamic page size
                    vm_size_t psize = di_get_page_size();
                    uintptr_t pmask = psize - 1;
                    uintptr_t page_addr = (uintptr_t)&indirect_symbol_bindings[i] & ~pmask;

                    kern_return_t kr = vm_protect(mach_task_self(),
                                                  (vm_address_t)page_addr,
                                                  psize,
                                                  0,
                                                  VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
                    if (kr == KERN_SUCCESS) {
                        indirect_symbol_bindings[i] = s_rebindings[r].replacement;
                        rewritten++;
                    }
                }
            }
        }
    }
    return rewritten;
}

/* Performs rebinding on a loaded Mach-O image */
static int rebind_image(const struct mach_header *header, intptr_t slide) {
    if (!header || header->magic != MH_MAGIC_64) return 0;
    const struct mach_header_64 *hdr64 = (const struct mach_header_64 *)header;

    const struct segment_command_64 *linkedit_cmd = NULL;
    const struct symtab_command *symtab_cmd = NULL;
    const struct dysymtab_command *dysymtab_cmd = NULL;

    const uint8_t *cmd_ptr = (const uint8_t *)(hdr64 + 1);
    for (uint32_t i = 0; i < hdr64->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)cmd_ptr;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
            if (strncmp(seg->segname, SEG_LINKEDIT, 16) == 0) {
                linkedit_cmd = seg;
            }
        } else if (lc->cmd == LC_SYMTAB) {
            symtab_cmd = (const struct symtab_command *)lc;
        } else if (lc->cmd == LC_DYSYMTAB) {
            dysymtab_cmd = (const struct dysymtab_command *)lc;
        }
        cmd_ptr += lc->cmdsize;
    }

    if (!linkedit_cmd || !symtab_cmd || !dysymtab_cmd) return 0;

    uintptr_t linkedit_base = (uintptr_t)(slide + linkedit_cmd->vmaddr - linkedit_cmd->fileoff);
    int total_rewritten = 0;

    // Scan segments for symbol pointer sections
    cmd_ptr = (const uint8_t *)(hdr64 + 1);
    for (uint32_t i = 0; i < hdr64->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)cmd_ptr;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
            const struct section_64 *sect = (const struct section_64 *)(seg + 1);
            for (uint32_t s = 0; s < seg->nsects; s++) {
                uint32_t type = sect[s].flags & SECTION_TYPE;
                if (type == S_LAZY_SYMBOL_POINTERS || type == S_NON_LAZY_SYMBOL_POINTERS) {
                    total_rewritten += rebind_section(hdr64, slide, linkedit_base,
                                                      symtab_cmd, dysymtab_cmd, &sect[s]);
                }
            }
        }
        cmd_ptr += lc->cmdsize;
    }
    return total_rewritten;
}

static void on_dyld_image_added(const struct mach_header *header, intptr_t slide) {
    pthread_mutex_lock(&s_rebind_lock);
    rebind_image(header, slide);
    pthread_mutex_unlock(&s_rebind_lock);
}

/* Attempts to locate and rewrite dyld's internal main executable path buffer */
static int patch_dyld_internal_path(const char *guest_path) {
    const char *img0 = _dyld_get_image_name(0);
    if (!img0) return -1;

    vm_size_t psize = di_get_page_size();
    uintptr_t pmask = psize - 1;
    size_t len = strlen(img0);
    if (strlen(guest_path) <= len) {
        uintptr_t page_start = (uintptr_t)img0 & ~pmask;
        uintptr_t page_end = ((uintptr_t)img0 + len + 1 + pmask) & ~pmask;
        vm_size_t protect_size = (vm_size_t)(page_end - page_start);

        kern_return_t kr = vm_protect(mach_task_self(),
                                      (vm_address_t)page_start,
                                      protect_size,
                                      0,
                                      VM_PROT_READ | VM_PROT_WRITE);
        if (kr == KERN_SUCCESS) {
            memcpy((void *)img0, guest_path, strlen(guest_path) + 1);
            return 0; // Successfully patched dyld internal path buffer
        }
    }
    return -1; // Dyld-internal pointer could not be overwritten in place
}

#else
// Non-Darwin mock implementations for testing and compilation verification
typedef struct {
    char name[128];
    void *replacement;
    void **original;
} RebindRule;

static RebindRule s_rebindings[MAX_REBINDINGS];
static size_t s_rebind_count = 0;

static int mock_patch_dyld_internal_path(const char *guest_path) {
    (void)guest_path;
    return -1; // dyld-internal pointer not present on non-Darwin host
}
#endif

int di_set_guest_executable_path(const char *guest_path) {
    if (!guest_path) {
        s_guest_path[0] = '\0';
        s_has_guest_path = 0;
        return 0;
    }

    size_t len = strlen(guest_path);
    if (len >= MAX_PATH_LEN) return -1;
    strncpy(s_guest_path, guest_path, MAX_PATH_LEN - 1);
    s_guest_path[MAX_PATH_LEN - 1] = '\0';
    s_has_guest_path = 1;

#if defined(__APPLE__)
    // Rebind _NSGetExecutablePath and NSGetExecutablePath
    di_rebind_symbol("_NSGetExecutablePath", (void *)interposed_NSGetExecutablePath,
                     (void **)&s_orig_NSGetExecutablePath);
    di_rebind_symbol("NSGetExecutablePath", (void *)interposed_NSGetExecutablePath,
                     (void **)&s_orig_NSGetExecutablePath);

    // Also rebind proc_pidpath to ensure consistency for libSystem/bundle lookups
    di_rebind_symbol("proc_pidpath", (void *)interposed_proc_pidpath,
                     (void **)&s_orig_proc_pidpath);

    // Attempt to patch dyld's internal main path pointer
    return patch_dyld_internal_path(guest_path);
#else
    return mock_patch_dyld_internal_path(guest_path);
#endif
}

const char *di_guest_executable_path(void) {
    return s_has_guest_path ? s_guest_path : NULL;
}

void di_enable_exit_interposing(void (*on_exit_cb)(int status)) {
    s_exit_callback = on_exit_cb;
#if defined(__APPLE__)
    di_rebind_symbol("exit", (void *)interposed_exit, (void **)&s_orig_exit);
    di_rebind_symbol("_exit", (void *)interposed__exit, (void **)&s_orig__exit);
#endif
}

int di_rebind_symbol(const char *symbol, void *replacement, void **original) {
    if (!symbol || !replacement) return -1;

#if defined(__APPLE__)
    pthread_mutex_lock(&s_rebind_lock);

    if (s_rebind_count >= MAX_REBINDINGS) {
        pthread_mutex_unlock(&s_rebind_lock);
        return -1;
    }

    // Register rule
    strncpy(s_rebindings[s_rebind_count].name, symbol, sizeof(s_rebindings[s_rebind_count].name) - 1);
    s_rebindings[s_rebind_count].replacement = replacement;
    s_rebindings[s_rebind_count].original = original;
    s_rebind_count++;

    // Register image listener for future dlopen() images if not done yet
    if (!s_listener_registered) {
        _dyld_register_func_for_add_image(on_dyld_image_added);
        s_listener_registered = 1;
    }

    // Immediately rebind in all currently loaded images
    int total_rewritten = 0;
    uint32_t img_count = _dyld_image_count();
    for (uint32_t i = 0; i < img_count; i++) {
        total_rewritten += rebind_image(_dyld_get_image_header(i), _dyld_get_image_vmaddr_slide(i));
    }

    pthread_mutex_unlock(&s_rebind_lock);
    return total_rewritten;
#else
    if (s_rebind_count >= MAX_REBINDINGS) return -1;
    strncpy(s_rebindings[s_rebind_count].name, symbol, sizeof(s_rebindings[s_rebind_count].name) - 1);
    s_rebindings[s_rebind_count].replacement = replacement;
    s_rebindings[s_rebind_count].original = original;
    s_rebind_count++;
    return 1;
#endif
}
