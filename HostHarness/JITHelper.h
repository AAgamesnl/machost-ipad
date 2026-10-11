// JITHelper.h - JIT initialization, memory protection, and pthread_jit_write_protect_np routines.

#ifndef JITHELPER_H
#define JITHELPER_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Returns 1 if JIT execution is available and functional, 0 otherwise
int jit_is_available(void);

// Initializes the JIT runtime environment and tests code execution capabilities
int jit_init_environment(void);

// Configures write protection for JIT regions:
// enable = 1 -> executable (write-protected)
// enable = 0 -> writable (execute-protected)
int jit_set_write_protect(int enable);

// Allocates a page of RWX / JIT memory with appropriate flags
void *jit_allocate_page(size_t size);

// Releases JIT memory
void jit_free_page(void *addr, size_t size);

#ifdef __cplusplus
}
#endif

#endif // JITHELPER_H
