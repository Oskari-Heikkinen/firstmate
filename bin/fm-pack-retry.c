/*
 * fm-pack-retry.c - an LD_PRELOAD shim that retries a read, write or open
 * that failed with ENOMEM, for the tools bin/fm-pack.sh runs.
 *
 * WSL mounts D: as 9p with msize=65536, so every 9p request needs a 64 KiB
 * (order-4) kernel buffer (p9_fcall_init). When memory is fragmented that
 * allocation fails and the call returns ENOMEM having moved no bytes; the
 * same call a moment later succeeds. docs/storage.md "Packing cold data" owns
 * the diagnosis, and bin/fm-pack.sh's header owns how the shim is built and
 * loaded.
 *
 * A wrapped call that fails with ENOMEM is tried again after 10 ms, doubling
 * to at most 1 s between tries, until it succeeds or FM_PACK_RETRY_LIMIT
 * seconds (default 600) have been waited, when ENOMEM is returned. A failed
 * read or write moved no bytes (a partial transfer returns its count), and
 * pread and pwrite carry their offset, so a retry is safe. A failed readdir
 * leaves the stream and the directory offset where they were. fread retries
 * only when the stream's error came from ENOMEM, after clearing it.
 *
 * Each call that was retried appends one line to FM_PACK_RETRY_LOG, if set:
 *   <comm> <pid> <call> retried=<n> waited_ms=<ms> result=ok|gave-up
 * Test hook: FM_PACK_RETRY_TEST_EVERY=N fails the first try of every Nth
 * wrapped call with ENOMEM without calling the real function.
 */
#define _GNU_SOURCE
#include <dirent.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/uio.h>
#include <time.h>
#include <unistd.h>

static long test_every;
static unsigned long test_calls;
static long limit_ms = 600000;
static const char *log_path;

__attribute__((constructor)) static void retry_init(void)
{
	const char *v;

	if ((v = getenv("FM_PACK_RETRY_TEST_EVERY")) != NULL)
		test_every = atol(v);
	if ((v = getenv("FM_PACK_RETRY_LIMIT")) != NULL && atol(v) >= 0)
		limit_ms = atol(v) * 1000;
	log_path = getenv("FM_PACK_RETRY_LOG");
	if (log_path != NULL && *log_path == '\0')
		log_path = NULL;
}

static int injected(void)
{
	return test_every > 0 &&
	       __atomic_fetch_add(&test_calls, 1, __ATOMIC_RELAXED) % (unsigned long)test_every == 0;
}

/* The log is written with raw syscalls so it never re-enters a wrapper. */
static void retry_log(const char *call, int tries, long waited, int ok)
{
	char comm[32] = "?", line[192];
	int fd, len, saved = errno;
	long r;

	if (log_path == NULL)
		return;
	fd = (int)syscall(SYS_openat, AT_FDCWD, "/proc/self/comm", O_RDONLY | O_CLOEXEC);
	if (fd >= 0) {
		r = syscall(SYS_read, fd, comm, sizeof comm - 1);
		comm[r > 0 ? r : 0] = '\0';
		comm[strcspn(comm, "\n")] = '\0';
		syscall(SYS_close, fd);
	}
	len = snprintf(line, sizeof line, "%s %ld %s retried=%d waited_ms=%ld result=%s\n",
		       comm, (long)getpid(), call, tries, waited, ok ? "ok" : "gave-up");
	fd = (int)syscall(SYS_openat, AT_FDCWD, log_path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0600);
	if (fd >= 0) {
		syscall(SYS_write, fd, line, (size_t)len);
		syscall(SYS_close, fd);
	}
	errno = saved;
}

/* backoff: sleep before the next try; 0 once the limit is spent. */
static int backoff(int *tries, long *waited)
{
	long step = 10L << (*tries < 7 ? *tries : 7);
	struct timespec t;

	if (step > 1000)
		step = 1000;
	if (*waited >= limit_ms)
		return 0;
	t.tv_sec = step / 1000;
	t.tv_nsec = (step % 1000) * 1000000L;
	while (nanosleep(&t, &t) == -1 && errno == EINTR)
		;
	*waited += step;
	(*tries)++;
	return 1;
}

#define REAL(name) \
	static __typeof__(name) *real; \
	if (real == NULL) \
		real = (__typeof__(name) *)dlsym(RTLD_NEXT, #name)

/* RETRY(name, type, call): run call, retrying while it fails with ENOMEM. */
#define RETRY(name, type, call) \
	do { \
		type r; \
		int tries = 0; \
		long waited = 0; \
		if (real == NULL) { \
			errno = ENOSYS; \
			return -1; \
		} \
		if (injected()) { \
			r = -1; \
			errno = ENOMEM; \
		} else { \
			r = call; \
		} \
		while (r == -1 && errno == ENOMEM && backoff(&tries, &waited)) \
			r = call; \
		if (tries > 0) \
			retry_log(name, tries, waited, !(r == -1 && errno == ENOMEM)); \
		return r; \
	} while (0)

ssize_t read(int fd, void *buf, size_t n)
{
	REAL(read);
	RETRY("read", ssize_t, real(fd, buf, n));
}

ssize_t write(int fd, const void *buf, size_t n)
{
	REAL(write);
	RETRY("write", ssize_t, real(fd, buf, n));
}

ssize_t pread(int fd, void *buf, size_t n, off_t off)
{
	REAL(pread);
	RETRY("pread", ssize_t, real(fd, buf, n, off));
}

ssize_t pread64(int fd, void *buf, size_t n, off64_t off)
{
	REAL(pread64);
	RETRY("pread64", ssize_t, real(fd, buf, n, off));
}

ssize_t pwrite(int fd, const void *buf, size_t n, off_t off)
{
	REAL(pwrite);
	RETRY("pwrite", ssize_t, real(fd, buf, n, off));
}

ssize_t pwrite64(int fd, const void *buf, size_t n, off64_t off)
{
	REAL(pwrite64);
	RETRY("pwrite64", ssize_t, real(fd, buf, n, off));
}

ssize_t readv(int fd, const struct iovec *iov, int cnt)
{
	REAL(readv);
	RETRY("readv", ssize_t, real(fd, iov, cnt));
}

ssize_t writev(int fd, const struct iovec *iov, int cnt)
{
	REAL(writev);
	RETRY("writev", ssize_t, real(fd, iov, cnt));
}

/* open(2) takes a mode only when it may create the file. */
#define OPEN_MODE(flags, mode) \
	do { \
		if ((flags) & (O_CREAT | O_TMPFILE)) { \
			va_list ap; \
			va_start(ap, flags); \
			mode = va_arg(ap, int); \
			va_end(ap); \
		} \
	} while (0)

int open(const char *path, int flags, ...)
{
	int mode = 0;
	OPEN_MODE(flags, mode);
	REAL(open);
	RETRY("open", int, real(path, flags, mode));
}

int open64(const char *path, int flags, ...)
{
	int mode = 0;
	OPEN_MODE(flags, mode);
	REAL(open64);
	RETRY("open64", int, real(path, flags, mode));
}

int openat(int dir, const char *path, int flags, ...)
{
	int mode = 0;
	OPEN_MODE(flags, mode);
	REAL(openat);
	RETRY("openat", int, real(dir, path, flags, mode));
}

int openat64(int dir, const char *path, int flags, ...)
{
	int mode = 0;
	OPEN_MODE(flags, mode);
	REAL(openat64);
	RETRY("openat64", int, real(dir, path, flags, mode));
}

/* The fortified opens a caller compiled with _FORTIFY_SOURCE binds to. */
int __open_2(const char *path, int flags)
{
	REAL(__open_2);
	RETRY("__open_2", int, real(path, flags));
}

int __open64_2(const char *path, int flags)
{
	REAL(__open64_2);
	RETRY("__open64_2", int, real(path, flags));
}

/*
 * readdir leaves errno alone at the end of the directory, so it is cleared
 * before each try and the caller's value put back when the end is reached.
 */
#define RETRY_DIR(name, call) \
	do { \
		__typeof__(call) r; \
		int tries = 0, saved = errno; \
		long waited = 0; \
		if (real == NULL) { \
			errno = ENOSYS; \
			return NULL; \
		} \
		errno = 0; \
		if (injected()) { \
			r = NULL; \
			errno = ENOMEM; \
		} else { \
			r = call; \
		} \
		while (r == NULL && errno == ENOMEM && backoff(&tries, &waited)) { \
			errno = 0; \
			r = call; \
		} \
		if (tries > 0) \
			retry_log(name, tries, waited, !(r == NULL && errno == ENOMEM)); \
		if (r == NULL && errno == 0) \
			errno = saved; \
		return r; \
	} while (0)

struct dirent *readdir(DIR *d)
{
	REAL(readdir);
	RETRY_DIR("readdir", real(d));
}

struct dirent64 *readdir64(DIR *d)
{
	REAL(readdir64);
	RETRY_DIR("readdir64", real(d));
}

/*
 * stdio reads go through glibc's internal read, which no wrapper above sees,
 * so fread and its variants are wrapped themselves. Each try asks for the
 * remaining bytes one byte-sized item at a time, so a short count is exact;
 * the result is whole items, as fread's own.
 */
typedef size_t fread_fn(void *, size_t, size_t, FILE *);
typedef size_t fread_chk_fn(void *, size_t, size_t, size_t, FILE *);

static size_t fread_retry(const char *name, fread_fn *plain, fread_chk_fn *chk, int unlocked,
			  void *ptr, size_t len, size_t size, size_t n, FILE *f)
{
	size_t want, got = 0;
	int tries = 0, gaveup = 0;
	long waited = 0;

	if (plain == NULL && chk == NULL) {
		errno = ENOSYS;
		return 0;
	}
	if (size == 0 || n == 0 || n > (size_t)-1 / size)
		return chk != NULL ? chk(ptr, len, size, n, f) : plain(ptr, size, n, f);
	want = size * n;
	for (;;) {
		if (got == 0 && tries == 0 && limit_ms > 0 && injected()) {
			errno = ENOMEM; /* nothing read, the stream untouched */
		} else {
			errno = 0;
			got += chk != NULL ? chk((char *)ptr + got, len - got, 1, want - got, f)
					   : plain((char *)ptr + got, 1, want - got, f);
			if (got >= want || errno != ENOMEM || !(unlocked ? ferror_unlocked(f) : ferror(f)))
				break;
			if (waited >= limit_ms) {
				gaveup = 1; /* the stream keeps its error for the caller */
				break;
			}
			if (unlocked)
				clearerr_unlocked(f);
			else
				clearerr(f);
		}
		if (!backoff(&tries, &waited))
			break;
	}
	if (tries > 0)
		retry_log(name, tries, waited, !gaveup);
	if (gaveup)
		errno = ENOMEM;
	return got / size;
}

#define FREAD_REAL(type, name) \
	static type *real; \
	if (real == NULL) \
		real = (type *)dlsym(RTLD_NEXT, name)

size_t fread(void *ptr, size_t size, size_t n, FILE *f)
{
	FREAD_REAL(fread_fn, "fread");
	return fread_retry("fread", real, NULL, 0, ptr, 0, size, n, f);
}

size_t fread_unlocked(void *ptr, size_t size, size_t n, FILE *f)
{
	FREAD_REAL(fread_fn, "fread_unlocked");
	return fread_retry("fread_unlocked", real, NULL, 1, ptr, 0, size, n, f);
}

size_t __fread_chk(void *ptr, size_t len, size_t size, size_t n, FILE *f);
size_t __fread_chk(void *ptr, size_t len, size_t size, size_t n, FILE *f)
{
	FREAD_REAL(fread_chk_fn, "__fread_chk");
	return fread_retry("__fread_chk", NULL, real, 0, ptr, len, size, n, f);
}

size_t __fread_unlocked_chk(void *ptr, size_t len, size_t size, size_t n, FILE *f);
size_t __fread_unlocked_chk(void *ptr, size_t len, size_t size, size_t n, FILE *f)
{
	FREAD_REAL(fread_chk_fn, "__fread_unlocked_chk");
	return fread_retry("__fread_unlocked_chk", NULL, real, 1, ptr, len, size, n, f);
}
