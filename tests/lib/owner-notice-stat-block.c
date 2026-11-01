/* Linux/glibc fixture only: intercept producer-path filesystem calls.
 * BLOCK_PREFIX, BLOCK_HITS, BLOCK_FIFO are all under a test's private root.
 * A FIFO release latches in this process only (R5-n3); other processes remain
 * blocked. BLOCK_DISABLE may name a test-owned file for final global recovery.
 * Syscalls below bypass our wrappers so recording/release cannot recurse.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>
#include <dirent.h>
#include <linux/stat.h>

static int released;
static int resolving;
static void block_path(int dirfd, const char *path, const char *call) {
    const char *prefix = getenv("BLOCK_PREFIX"), *fifo = getenv("BLOCK_FIFO");
    const char *hits = getenv("BLOCK_HITS"), *disable = getenv("BLOCK_DISABLE");
    const char *calls = getenv("BLOCK_CALLS");
    char absolute[4096], resolved[4096], fdpath[64], base[4096], line[4608], comm[64] = "unknown";
    if (released || resolving || !path || !prefix || !*prefix || !fifo || !hits) return;
    if (calls && !strstr(calls, call)) return;
    if (disable && syscall(SYS_faccessat, AT_FDCWD, disable, F_OK) == 0) return;
    if (path[0] != '/') {
        if (dirfd == AT_FDCWD) {
            if (!getcwd(base, sizeof base)) return;
        } else {
            snprintf(fdpath, sizeof fdpath, "/proc/self/fd/%d", dirfd);
            ssize_t n = readlink(fdpath, base, sizeof base - 1);
            if (n < 0) return;
            base[n] = 0;
        }
        snprintf(absolute, sizeof absolute, "%s/%s", base, path);
        path = absolute;
    }
    size_t n = strlen(prefix);
    if (strncmp(path, prefix, n) || (path[n] && path[n] != '/' && prefix[n-1] != '/')) {
        /* The fixture may redirect an intermediate directory after binding. */
        resolving = 1;
        char *canonical = realpath(path, resolved);
        resolving = 0;
        if (!canonical) return;
        path = canonical;
        if (strncmp(path, prefix, n) || (path[n] && path[n] != '/' && prefix[n-1] != '/')) return;
    }
    int fd = syscall(SYS_openat, AT_FDCWD, "/proc/self/comm", O_RDONLY, 0);
    if (fd >= 0) {
        ssize_t count = read(fd, comm, sizeof comm - 1);
        close(fd);
        if (count > 0) comm[count] = 0;
        comm[strcspn(comm, "\n")] = 0;
    }
    n = snprintf(line, sizeof line, "%ld %s %s %s\n", (long)getpid(), comm, call, path);
    fd = syscall(SYS_openat, AT_FDCWD, hits, O_WRONLY|O_CREAT|O_APPEND, 0600);
    if (fd >= 0) { write(fd, line, n < sizeof line ? n : sizeof line - 1); close(fd); }
    fd = syscall(SYS_openat, AT_FDCWD, fifo, O_RDONLY, 0);
    if (fd >= 0) { char byte; read(fd, &byte, 1); close(fd); released = 1; }
}
#define PATH_STAT(name, type) \
int name(const char *p, type *s) { \
    static int (*real)(const char *, type *); \
    if (!real) real = dlsym(RTLD_NEXT, #name); \
    block_path(AT_FDCWD, p, #name); return real(p, s); }
PATH_STAT(stat, struct stat)
PATH_STAT(lstat, struct stat)
PATH_STAT(stat64, struct stat64)
PATH_STAT(lstat64, struct stat64)
#define XSTAT(name, type) \
int name(int v, const char *p, type *s) { \
    static int (*real)(int, const char *, type *); \
    if (!real) real = dlsym(RTLD_NEXT, #name); \
    block_path(AT_FDCWD, p, #name); return real(v,p,s); }
XSTAT(__xstat, struct stat)
XSTAT(__lxstat, struct stat)
XSTAT(__xstat64, struct stat64)
XSTAT(__lxstat64, struct stat64)
#define ATSTAT(name, type) \
int name(int d, const char *p, type *s, int f) { \
    static int (*real)(int,const char *,type *,int); \
    if (!real) real = dlsym(RTLD_NEXT,#name); \
    block_path(d,p,#name); return real(d,p,s,f); }
ATSTAT(fstatat, struct stat)
ATSTAT(fstatat64, struct stat64)
int statx(int d, const char *p, int f, unsigned m, struct statx *s) {
    static int (*real)(int,const char *,int,unsigned,struct statx *);
    if (!real) real = dlsym(RTLD_NEXT,"statx");
    block_path(d,p,"statx"); return real(d,p,f,m,s);
}
#define OPEN(name) \
int name(const char *p, int f, ...) { \
    static int (*real)(const char *,int,...); mode_t m=0; \
    if ((f & O_CREAT) || (f & O_TMPFILE) == O_TMPFILE) { va_list a; va_start(a,f); m=va_arg(a,int); va_end(a); } \
    if (!real) real=dlsym(RTLD_NEXT,#name); \
    block_path(AT_FDCWD,p,#name); return real(p,f,m); }
OPEN(open)
OPEN(open64)
#define OPENAT(name) \
int name(int d,const char *p,int f,...) { \
    static int (*real)(int,const char *,int,...); mode_t m=0; \
    if ((f & O_CREAT) || (f & O_TMPFILE) == O_TMPFILE) { va_list a; va_start(a,f); m=va_arg(a,int); va_end(a); } \
    if (!real) real=dlsym(RTLD_NEXT,#name); \
    block_path(d,p,#name); return real(d,p,f,m); }
OPENAT(openat)
OPENAT(openat64)
DIR *opendir(const char *p) {
    static DIR *(*real)(const char *);
    if (!real) real=dlsym(RTLD_NEXT,"opendir");
    block_path(AT_FDCWD,p,"opendir"); return real(p);
}
