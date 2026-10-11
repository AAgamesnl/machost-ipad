// JITHelper.m - JIT initialization, memory protection, and pthread_jit_write_protect_np routines.

#include "JITHelper.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(__APPLE__)
#include <dlfcn.h>
#include <unistd.h>
#include <sys/mman.h>
#include <libkern/OSCacheControl.h>
#include <pthread.h>
#include <signal.h>
#include <setjmp.h>

// Dynamic function pointer for pthread_jit_write_protect_np
typedef void (*pthread_jit_write_protect_np_func)(int enabled);
static pthread_jit_write_protect_np_func s_pthread_jit_write_protect_np = NULL;
static int s_jit_status = -1; // -1 = uninitialized, 0 = unavailable, 1 = available

#ifndef MAP_JIT
#define MAP_JIT 0x0800
#endif

static sigjmp_buf s_jit_fault_jmp;
static void jit_fault_signal_handler(int sig) {
    (void)sig;
    siglongjmp(s_jit_fault_jmp, 1);
}

int jit_set_write_protect(int enable) {
    if (!s_pthread_jit_write_protect_np) {
        s_pthread_jit_write_protect_np = (pthread_jit_write_protect_np_func)dlsym(RTLD_DEFAULT, "pthread_jit_write_protect_np");
    }
    if (s_pthread_jit_write_protect_np) {
        s_pthread_jit_write_protect_np(enable);
        return 0;
    }
    return -1;
}

void *jit_allocate_page(size_t size) {
    size_t pageSize = (size_t)sysconf(_SC_PAGESIZE);
    size_t allocSize = (size + pageSize - 1) & ~(pageSize - 1);

    // Try allocating with MAP_JIT first
    void *ptr = mmap(NULL, allocSize, PROT_READ | PROT_WRITE | PROT_EXEC,
                     MAP_ANON | MAP_PRIVATE | MAP_JIT, -1, 0);
    if (ptr == MAP_FAILED) {
        // Fallback to standard PROT_READ | PROT_WRITE with mprotect later
        ptr = mmap(NULL, allocSize, PROT_READ | PROT_WRITE,
                   MAP_ANON | MAP_PRIVATE, -1, 0);
    }
    return (ptr == MAP_FAILED) ? NULL : ptr;
}

void jit_free_page(void *addr, size_t size) {
    if (!addr) return;
    size_t pageSize = (size_t)sysconf(_SC_PAGESIZE);
    size_t allocSize = (size + pageSize - 1) & ~(pageSize - 1);
    munmap(addr, allocSize);
}

int jit_init_environment(void) {
    if (s_jit_status >= 0) return s_jit_status;

    // Resolve pthread_jit_write_protect_np
    s_pthread_jit_write_protect_np = (pthread_jit_write_protect_np_func)dlsym(RTLD_DEFAULT, "pthread_jit_write_protect_np");

    // Test JIT memory allocation and execution
    size_t pageSize = (size_t)sysconf(_SC_PAGESIZE);
    void *code = mmap(NULL, pageSize, PROT_READ | PROT_WRITE,
                      MAP_ANON | MAP_PRIVATE | MAP_JIT, -1, 0);

    if (code == MAP_FAILED) {
        s_jit_status = 0;
        return 0;
    }

    // Write a simple ARM64 function:
    // mov w0, #42   -> 0x52800540
    // ret           -> 0xd65f03c0
    jit_set_write_protect(0); // Allow write
    uint32_t *insn = (uint32_t *)code;
    insn[0] = 0x52800540;
    insn[1] = 0xd65f03c0;

    // Flush instruction cache
    sys_dcache_flush(code, sizeof(uint32_t) * 2);
    sys_icache_invalidate(code, sizeof(uint32_t) * 2);

    jit_set_write_protect(1); // Protect write, enable execute

    // Set up crash-guard signal handlers to safely catch SIGBUS / SIGSEGV if JIT is denied
    struct sigaction sa, old_bus, old_segv;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = jit_fault_signal_handler;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGBUS, &sa, &old_bus);
    sigaction(SIGSEGV, &sa, &old_segv);

    int result = -1;
    if (sigsetjmp(s_jit_fault_jmp, 1) == 0) {
        int (*test_fn)(void) = (int (*)(void))code;
        result = test_fn();
    } else {
        result = -1; // Safely intercepted kernel JIT fault without crashing app
    }

    sigaction(SIGBUS, &old_bus, NULL);
    sigaction(SIGSEGV, &old_segv, NULL);

    munmap(code, pageSize);

    if (result == 42) {
        s_jit_status = 1;
        return 1;
    } else {
        s_jit_status = 0;
        return 0;
    }
}

int jit_is_available(void) {
    if (s_jit_status < 0) {
        return jit_init_environment();
    }
    return s_jit_status;
}

#else

int jit_set_write_protect(int enable) {
    (void)enable;
    return 0;
}

void *jit_allocate_page(size_t size) {
    return malloc(size);
}

void jit_free_page(void *addr, size_t size) {
    (void)size;
    free(addr);
}

int jit_init_environment(void) {
    return 1;
}

int jit_is_available(void) {
    return 1;
}

#endif
