// SPDX-License-Identifier: GPL-3.0-or-later
// Build the pinned upstream console adapter with a variadic fcntl correction.
// Portions adapted from ps5-native-app-boilerplate and ps5-homebrew-ui.
// Copyright (C) 2026 BlackBearReloaded and BruTV contributors.
// Its DNS and certificate-date implementations are real platform adapters.
#define __wrap_fcntl brutv_unused_upstream_fcntl
#define mkstemp brutv_unused_upstream_mkstemp
#include <console_curl.c>
#undef __wrap_fcntl
#undef mkstemp

// Override the SDK helper's weak 128 MiB default for bounded image-decoder,
// CPU/GPU cache, FFmpeg frame, and font overlap. The helper prefers direct
// memory above 128 MiB and retains its original allocator fallback behavior.
const size_t ps5_opengl_heap_size = 256u * 1024u * 1024u;

int __wrap_fcntl(int descriptor, int command, ...)
{
    intptr_t argument = 0;
    if (command != F_GETFD && command != F_GETFL
#ifdef F_GETOWN
        && command != F_GETOWN
#endif
    ) {
        va_list arguments;
        va_start(arguments, command);
        // The relevant F_SET* commands take promoted integers; lock commands
        // take pointers. Do not read a nonexistent argument for F_GET* calls.
        switch (command) {
        case F_SETFD:
        case F_SETFL:
#ifdef F_SETOWN
        case F_SETOWN:
#endif
        case F_DUPFD:
#ifdef F_DUPFD_CLOEXEC
        case F_DUPFD_CLOEXEC:
#endif
            argument = va_arg(arguments, int);
            break;
        default:
            argument = (intptr_t)va_arg(arguments, void *);
            break;
        }
        va_end(arguments);
    }
    const int result = __real_fcntl(descriptor, command, argument);
    if (result >= 0 || errno != EINVAL)
        return result;
    if (command == F_GETFD || command == F_SETFD || command == F_SETFL || command == F_GETFL)
        return console_curl_socket_flags(descriptor, command, (int)argument);
    return result;
}

// The application stores and formats timestamps in UTC. A native title has no
// system timezone database; explicitly preserve correct UTC calendar values.
struct tm *localtime_r(const time_t *when, struct tm *out)
{
    return gmtime_r(when, out);
}

__attribute__((noreturn)) void __assert(const char *function, const char *file,
                                        int line, const char *expression)
{
    fprintf(stderr, "[BruTV] assertion failed: %s (%s:%d, %s)\n", expression, file, line, function);
    abort();
}

extern uint64_t sceKernelGetProcessTime(void);
int mkstemps(char *template_name, int suffix_length)
{
    static const char letters[] = "abcdefghijklmnopqrstuvwxyz0123456789";
    static unsigned counter;
    const size_t length = template_name ? strlen(template_name) : 0;
    if (suffix_length < 0 || length < (size_t)suffix_length + 6u) {
        errno = EINVAL;
        return -1;
    }
    char *name = template_name + length - (size_t)suffix_length - 6u;
    for (int i = 0; i < 6; ++i) {
        if (name[i] != 'X') { errno = EINVAL; return -1; }
    }
    for (int attempt = 0; attempt < 100; ++attempt) {
        uint64_t value = sceKernelGetProcessTime() +
            (uint64_t)__atomic_add_fetch(&counter, 1u, __ATOMIC_RELAXED) * UINT64_C(0x9E3779B97F4A7C15);
        for (int i = 0; i < 6; ++i) { name[i] = letters[value % 36u]; value /= 36u; }
        const int file = open(template_name, O_RDWR | O_CREAT | O_EXCL, 0600);
        if (file >= 0 || errno != EEXIST) return file;
    }
    errno = EEXIST;
    return -1;
}

int mkstemp(char *template_name) { return mkstemps(template_name, 0); }

// The native pthread naming entry point hangs on the reference environment.
// Naming is optional; a truthful unsupported result avoids touching the thread.
int __wrap_pthread_setname_np(pthread_t thread, const char *name)
{
    (void)thread;
    (void)name;
    return ENOSYS;
}

// FFmpeg 7 uses the FreeBSD spelling, whose public SDK ABI returns void.
// Skip optional diagnostic metadata on this native runtime as well.
void __wrap_pthread_set_name_np(pthread_t thread, const char *name)
{
    (void)thread;
    (void)name;
}

#include <langinfo.h>
// Only the C locale is exposed to libc++ and iconv; the renderer consumes UTF-8
// directly and does not depend on the C locale's multibyte conversion routines.
char *nl_langinfo(nl_item item)
{
    if (item == CODESET) return "US-ASCII";
    errno = EINVAL;
    return "";
}
int ___mb_cur_max(void) { return 1; }

// Mesa defines this emulated thread-local pointer in C with a zero initializer.
// C++ consumers emit an optional dynamic-initializer hook. There is no dynamic
// work to perform; __emutls_get_address supplies the real per-thread storage.
void brutv_mesa_tls_static_init(void) __asm__("_ZTH23_mesa_glapi_tls_Context");
void brutv_mesa_tls_static_init(void) {}

#include <dirent.h>
// Native titles do not load libScePosixForWebKit. Implement directory iteration
// on the real kernel getdents syscall instead of importing its unavailable DIR
// helpers. DIR remains opaque to every caller.
struct BrutvDirectory {
    int descriptor;
    size_t offset, length;
    struct dirent current;
    unsigned char buffer[8192];
};

DIR *opendir(const char *path)
{
    const int descriptor = open(path, O_RDONLY | O_DIRECTORY);
    if (descriptor < 0) return NULL;
    struct BrutvDirectory *directory = calloc(1, sizeof(*directory));
    if (directory == NULL) {
        const int saved = errno;
        close(descriptor);
        errno = saved;
        return NULL;
    }
    directory->descriptor = descriptor;
    return (DIR *)directory;
}

struct dirent *readdir(DIR *opaque)
{
    struct BrutvDirectory *directory = (struct BrutvDirectory *)opaque;
    if (directory == NULL) { errno = EBADF; return NULL; }
    for (;;) {
        if (directory->offset == directory->length) {
            const int bytes = getdents(directory->descriptor, (char *)directory->buffer, sizeof(directory->buffer));
            if (bytes <= 0) return NULL;
            directory->offset = 0;
            directory->length = (size_t)bytes;
        }
        const size_t remaining = directory->length - directory->offset;
        const unsigned char *record = directory->buffer + directory->offset;
        if (remaining < offsetof(struct dirent, d_name) + 1) { errno = EIO; return NULL; }
        struct dirent entry;
        memset(&entry, 0, sizeof(entry));
        memcpy(&entry, record, remaining < sizeof(entry) ? remaining : sizeof(entry));
        if (entry.d_reclen > remaining || entry.d_reclen < offsetof(struct dirent, d_name) + (size_t)entry.d_namlen + 1 ||
            (entry.d_reclen & 3u) != 0 || entry.d_name[entry.d_namlen] != '\0') {
            errno = EIO;
            return NULL;
        }
        directory->offset += entry.d_reclen;
        if (entry.d_fileno == 0) continue;
        directory->current = entry;
        return &directory->current;
    }
}

int closedir(DIR *opaque)
{
    struct BrutvDirectory *directory = (struct BrutvDirectory *)opaque;
    if (directory == NULL) { errno = EBADF; return -1; }
    const int result = close(directory->descriptor);
    free(directory);
    return result;
}

extern int sysctlbyname(const char *name, void *old_value, size_t *old_length,
                        const void *new_value, size_t new_length);
static void brutv_wipe(void *buffer, size_t size)
{
    volatile unsigned char *output = buffer;
    while (size != 0) { *output++ = 0; --size; }
}
// ProsperoLight's kernel entropy backend avoids a libSceRandom import, which is
// absent in a documented native-title mapping on firmware 13.00. This is the
// kernel random service, not a user-space pseudo-random fallback.
void arc4random_buf(void *buffer, size_t size)
{
    const size_t total = size;
    unsigned char *output = buffer;
    while (size != 0) {
        unsigned char block[64] = {0};
        const size_t chunk = size < sizeof(block) ? size : sizeof(block);
        size_t received = sizeof(block);
        if (sysctlbyname("kern.rng_pseudo", block, &received, NULL, 0) != 0 ||
            received < chunk || received > sizeof(block)) {
            // Never substitute non-cryptographic entropy for OpenSSL.
            brutv_wipe(block, sizeof(block));
            brutv_wipe(buffer, total);
            fprintf(stderr, "[BruTV] secure random source failed\n");
            abort();
        }
        memcpy(output, block, chunk);
        brutv_wipe(block, sizeof(block));
        output += chunk;
        size -= chunk;
    }
}

extern int sceKernelUsleep(unsigned microseconds);
extern int sceSystemServiceLoadExec(const char *path, const char **arguments);
// The shell owns native-title termination. Returning through the generic libc
// exit path is not validated for this runtime; request closure through the shell.
__attribute__((noreturn)) void catchReturnFromMain(int status)
{
    fprintf(stderr, "[BruTV] main completed with status %d\n", status);
    fflush(NULL);
    const int result = sceSystemServiceLoadExec("exit", NULL);
    fprintf(stderr, "[BruTV] shell close request returned 0x%08x; waiting for shell closure\n", (unsigned)result);
    fflush(NULL);
    for (;;) sceKernelUsleep(100000);
}
