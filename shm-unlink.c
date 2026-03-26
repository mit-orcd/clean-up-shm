/*
 * shm-unlink — TOCTOU-safe file removal confined to a root directory.
 *
 * Designed as a helper for cleanup-shm.sh. Atomically verifies that each
 * target path resolves within the specified root directory before unlinking,
 * eliminating the time-of-check-to-time-of-use race that affects shell-based
 * path validation + rm sequences.
 *
 * Primary path:  openat2(RESOLVE_BENEATH) → /proc/self/fd verify → unlinkat()
 * Fallback path: open(O_PATH|O_NOFOLLOW)  → /proc/self/fd verify → unlinkat()
 *
 * Build (static, musl):
 *   musl-gcc -O2 -static -o shm-unlink shm-unlink.c
 *
 * Build (glibc, dynamic):
 *   gcc -O2 -Wall -Wextra -o shm-unlink shm-unlink.c
 *
 * Usage:
 *   shm-unlink --root /dev/shm <path> [<path> ...]
 *   find ... -print0 | shm-unlink --root /dev/shm --stdin0
 *
 * Exit codes:
 *   0 — All files successfully unlinked (or nothing to do).
 *   1 — One or more files could not be unlinked.
 *   2 — Usage error, not root, or missing capabilities.
 */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

/* --- openat2 / RESOLVE_* may not be in older headers --- */

#ifdef __has_include
# if __has_include(<linux/openat2.h>)
#  include <linux/openat2.h>
#  define HAVE_OPENAT2_HEADER 1
# endif
#endif

#ifndef HAVE_OPENAT2_HEADER
struct open_how {
    __u64 flags;
    __u64 mode;
    __u64 resolve;
};
# ifndef RESOLVE_BENEATH
#  define RESOLVE_BENEATH    0x08
# endif
# ifndef RESOLVE_NO_SYMLINKS
#  define RESOLVE_NO_SYMLINKS 0x04
# endif
#endif /* !HAVE_OPENAT2_HEADER */

#ifndef AT_EMPTY_PATH
# define AT_EMPTY_PATH 0x1000
#endif

#ifndef SYS_openat2
# if defined(__x86_64__)
#  define SYS_openat2 437
# elif defined(__aarch64__)
#  define SYS_openat2 437
# elif defined(__i386__)
#  define SYS_openat2 437
# else
#  error "Unknown architecture — define SYS_openat2 manually"
# endif
#endif

/* --- Globals --- */

static const char *prog_name = "shm-unlink";
static int opt_verbose = 0;
static int opt_dry_run = 0;
static int have_openat2 = -1; /* -1 = untested, 0 = no, 1 = yes */

/* --- Logging --- */

#define LOG_OK    "OK"
#define LOG_SKIP  "SKIP"
#define LOG_ERR   "ERR"
#define LOG_DRY   "DRYRUN"

static void log_action(const char *status, const char *path, const char *detail) {
    fprintf(stderr, "%s: %s: %s%s%s\n",
            prog_name, status, path,
            detail ? ": " : "",
            detail ? detail : "");
}

/* --- Syscall wrappers --- */

static int sys_openat2(int dirfd, const char *path,
                       struct open_how *how, size_t size) {
    return (int)syscall(SYS_openat2, dirfd, path, how, size);
}

/*
 * Resolve the kernel's view of an fd via /proc/self/fd/<fd>.
 * Returns the length of the resolved path, or -1 on error.
 * The result is always null-terminated.
 */
static ssize_t fd_readlink(int fd, char *buf, size_t bufsz) {
    char proc_path[64];
    snprintf(proc_path, sizeof(proc_path), "/proc/self/fd/%d", fd);

    ssize_t len = readlink(proc_path, buf, bufsz - 1);
    if (len < 0)
        return -1;
    buf[len] = '\0';
    return len;
}

/*
 * Check whether `path` starts with `prefix/`.
 * Requires exact prefix match followed by '/' to prevent
 * /dev/shm2 matching /dev/shm.
 */
static int path_under(const char *path, const char *prefix, size_t prefix_len) {
    return strncmp(path, prefix, prefix_len) == 0
        && path[prefix_len] == '/';
}

/* --- Core: open a file descriptor confined beneath root_fd --- */

/*
 * Try openat2() with RESOLVE_BENEATH | RESOLVE_NO_SYMLINKS.
 * Returns fd on success, -1 on failure.
 * Sets have_openat2 = 0 if the syscall is not available (ENOSYS).
 */
static int open_beneath(int root_fd, const char *relpath) {
    struct open_how how = {
        .flags   = O_PATH | O_NOFOLLOW,
        .mode    = 0,
        .resolve = RESOLVE_BENEATH | RESOLVE_NO_SYMLINKS,
    };

    int fd = sys_openat2(root_fd, relpath, &how, sizeof(how));
    if (fd < 0 && errno == ENOSYS) {
        have_openat2 = 0;
        return -1;
    }
    if (fd >= 0)
        have_openat2 = 1;
    return fd;
}

/*
 * Fallback: open with O_PATH | O_NOFOLLOW (no RESOLVE_BENEATH).
 * Caller MUST verify containment via fd_readlink() afterward.
 */
static int open_nofollow(int root_fd, const char *relpath) {
    return openat(root_fd, relpath, O_PATH | O_NOFOLLOW | O_NOCTTY);
}

/*
 * Verify that the fd resolves to a path under root_resolved.
 * Returns 0 if safe, -1 if not (with errno set to EXDEV).
 */
static int verify_fd_containment(int fd, const char *root_resolved,
                                 size_t root_resolved_len) {
    char resolved[PATH_MAX];
    ssize_t len = fd_readlink(fd, resolved, sizeof(resolved));
    if (len < 0)
        return -1;

    if (!path_under(resolved, root_resolved, root_resolved_len)) {
        errno = EXDEV;
        return -1;
    }
    return 0;
}

/* --- Core: safe unlink of a regular file (non-symlink) --- */

/*
 * Open the file at `relpath` (relative to root_fd) without following
 * symlinks, verify containment, and unlink via the fd.
 *
 * Returns 0 on success, -1 on failure with errno set.
 */
static int safe_unlink_file(int root_fd, const char *relpath,
                            const char *root_resolved, size_t root_resolved_len) {
    int fd = -1;

    /* Try openat2 first, fall back to openat + verify */
    if (have_openat2 != 0)
        fd = open_beneath(root_fd, relpath);

    if (fd < 0 && have_openat2 == 0)
        fd = open_nofollow(root_fd, relpath);

    if (fd < 0)
        return -1;

    /* Belt-and-suspenders: always verify via /proc/self/fd, even if
     * openat2(RESOLVE_BENEATH) succeeded. Defense-in-depth. */
    if (verify_fd_containment(fd, root_resolved, root_resolved_len) < 0) {
        close(fd);
        return -1;
    }

    /* Unlink via the fd — no path re-resolution */
    int ret = unlinkat(fd, "", AT_EMPTY_PATH);
    if (ret < 0 && errno == ENOENT) {
        /* Already gone — not an error */
        close(fd);
        return 0;
    }
    close(fd);
    return ret;
}

/* --- Core: safe unlink of a symlink --- */

/*
 * Symlinks cannot be opened with O_PATH|O_NOFOLLOW in a way that lets
 * us unlinkat(fd, "", AT_EMPTY_PATH) the link itself — O_NOFOLLOW
 * returns ELOOP for the final symlink component.
 *
 * Instead: open the parent directory beneath root_fd, verify the parent
 * is contained, then unlinkat(parent_fd, basename, 0).
 */
static int safe_unlink_symlink(int root_fd, const char *relpath,
                               const char *root_resolved,
                               size_t root_resolved_len) {
    /* Split relpath into parent + basename */
    char pathbuf[PATH_MAX];
    size_t len = strlen(relpath);
    if (len == 0 || len >= PATH_MAX) {
        errno = ENAMETOOLONG;
        return -1;
    }
    memcpy(pathbuf, relpath, len + 1);

    /* Find the last '/' */
    char *slash = strrchr(pathbuf, '/');
    const char *basename_ptr;
    const char *parent_rel;

    if (slash) {
        *slash = '\0';
        basename_ptr = slash + 1;
        parent_rel = pathbuf;
    } else {
        /* File directly under root */
        basename_ptr = relpath;
        parent_rel = ".";
    }

    if (basename_ptr[0] == '\0') {
        errno = EINVAL;
        return -1;
    }

    /* Reject basename containing path separators (shouldn't happen, but
     * defense-in-depth against crafted names) */
    if (strchr(basename_ptr, '/')) {
        errno = EINVAL;
        return -1;
    }

    /* Open parent directory beneath root */
    int parent_fd = -1;

    if (have_openat2 != 0) {
        struct open_how how = {
            .flags   = O_PATH | O_DIRECTORY,
            .mode    = 0,
            .resolve = RESOLVE_BENEATH | RESOLVE_NO_SYMLINKS,
        };
        parent_fd = sys_openat2(root_fd, parent_rel, &how, sizeof(how));
        if (parent_fd < 0 && errno == ENOSYS)
            have_openat2 = 0;
        else if (parent_fd >= 0)
            have_openat2 = 1;
    }

    if (parent_fd < 0 && have_openat2 == 0)
        parent_fd = openat(root_fd, parent_rel, O_PATH | O_DIRECTORY | O_NOCTTY);

    if (parent_fd < 0)
        return -1;

    /* Verify parent is under root */
    if (verify_fd_containment(parent_fd, root_resolved, root_resolved_len) < 0) {
        /* Also allow parent == root exactly */
        char resolved[PATH_MAX];
        if (fd_readlink(parent_fd, resolved, sizeof(resolved)) < 0 ||
            strcmp(resolved, root_resolved) != 0) {
            close(parent_fd);
            return -1;
        }
    }

    /* unlinkat with the parent fd — removes the directory entry (symlink)
     * without following it */
    int ret = unlinkat(parent_fd, basename_ptr, 0);
    if (ret < 0 && errno == ENOENT)
        ret = 0;  /* already gone */
    close(parent_fd);
    return ret;
}

/* --- Dispatch: detect type and call appropriate unlinker --- */

static int safe_unlink(int root_fd, const char *relpath,
                       const char *root_resolved, size_t root_resolved_len,
                       const char *display_path) {
    if (opt_dry_run) {
        log_action(LOG_DRY, display_path, NULL);
        return 0;
    }

    /*
     * Try the regular file path first. If it fails with ELOOP, the
     * final component is a symlink — use the symlink path.
     */
    int ret = safe_unlink_file(root_fd, relpath, root_resolved, root_resolved_len);
    if (ret < 0 && errno == ELOOP) {
        ret = safe_unlink_symlink(root_fd, relpath, root_resolved, root_resolved_len);
    }

    if (ret == 0) {
        log_action(LOG_OK, display_path, NULL);
    } else {
        log_action(LOG_ERR, display_path, strerror(errno));
    }
    return ret;
}

/* --- Path helpers --- */

/*
 * Given an absolute path and the root prefix, return a pointer to the
 * relative portion (after root + '/').  If the path doesn't start with
 * root, return NULL.
 */
static const char *make_relative(const char *path, const char *root,
                                 size_t root_len) {
    if (strncmp(path, root, root_len) == 0 && path[root_len] == '/')
        return path + root_len + 1;
    return NULL;
}

/* --- Input processing --- */

static int process_path(int root_fd, const char *path,
                        const char *root_resolved, size_t root_resolved_len) {
    /* Skip empty strings */
    if (path[0] == '\0')
        return 0;

    const char *relpath;

    if (path[0] == '/') {
        /* Absolute path — strip the root prefix */
        relpath = make_relative(path, root_resolved, root_resolved_len);
        if (!relpath) {
            log_action(LOG_SKIP, path, "not under root");
            errno = EXDEV;
            return -1;
        }
    } else {
        /* Already relative */
        relpath = path;
    }

    /* Reject paths that try to escape via .. */
    if (strstr(relpath, "..") != NULL) {
        /* More precise check: reject ".." as a standalone component */
        const char *p = relpath;
        while (*p) {
            if (p[0] == '.' && p[1] == '.' && (p[2] == '/' || p[2] == '\0')) {
                log_action(LOG_SKIP, path, "contains '..' component");
                errno = EXDEV;
                return -1;
            }
            /* Advance to next component */
            while (*p && *p != '/') p++;
            while (*p == '/') p++;
        }
    }

    /* Reject empty relative path (would refer to root itself) */
    if (relpath[0] == '\0') {
        log_action(LOG_SKIP, path, "refers to root directory itself");
        errno = EINVAL;
        return -1;
    }

    return safe_unlink(root_fd, relpath, root_resolved, root_resolved_len, path);
}

static int process_stdin0(int root_fd, const char *root_resolved,
                          size_t root_resolved_len) {
    char *buf = NULL;
    size_t bufsz = 0;
    ssize_t len;
    int failures = 0;

    while ((len = getdelim(&buf, &bufsz, '\0', stdin)) != -1) {
        /* getdelim includes the delimiter; strip it */
        if (len > 0 && buf[len - 1] == '\0')
            buf[len - 1] = '\0';

        if (process_path(root_fd, buf, root_resolved, root_resolved_len) < 0)
            failures++;
    }

    free(buf);
    return failures;
}

/* --- Usage / argument parsing --- */

static void usage(void) {
    fprintf(stderr,
        "Usage: %s --root <dir> [options] [<path> ...]\n"
        "       find ... -print0 | %s --root <dir> --stdin0\n"
        "\n"
        "TOCTOU-safe file removal confined beneath a root directory.\n"
        "\n"
        "Options:\n"
        "  --root <dir>   Root directory (required). Files are verified to\n"
        "                 resolve under this directory before unlinking.\n"
        "  --stdin0       Read null-delimited paths from stdin.\n"
        "  --dry-run      Log what would be removed without deleting.\n"
        "  --verbose      Log successful removals (default: errors only).\n"
        "  -h, --help     Show this message.\n"
        "\n"
        "Exit codes:\n"
        "  0  All files unlinked (or nothing to do).\n"
        "  1  One or more files could not be unlinked.\n"
        "  2  Usage error or insufficient privileges.\n",
        prog_name, prog_name);
}

int main(int argc, char *argv[]) {
    const char *root_arg = NULL;
    int opt_stdin0 = 0;
    int first_path_arg = -1;

    if (argc > 0)
        prog_name = argv[0];

    /* --- Parse arguments --- */
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--root") == 0) {
            if (i + 1 >= argc) {
                fprintf(stderr, "%s: --root requires an argument\n", prog_name);
                return 2;
            }
            root_arg = argv[++i];
        } else if (strcmp(argv[i], "--stdin0") == 0) {
            opt_stdin0 = 1;
        } else if (strcmp(argv[i], "--dry-run") == 0) {
            opt_dry_run = 1;
        } else if (strcmp(argv[i], "--verbose") == 0) {
            opt_verbose = 1;
        } else if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
            usage();
            return 0;
        } else if (argv[i][0] == '-') {
            fprintf(stderr, "%s: unknown option: %s\n", prog_name, argv[i]);
            return 2;
        } else {
            /* First non-option argument — paths start here */
            first_path_arg = i;
            break;
        }
    }

    if (!root_arg) {
        fprintf(stderr, "%s: --root is required\n", prog_name);
        usage();
        return 2;
    }

    if (!opt_stdin0 && first_path_arg < 0) {
        fprintf(stderr, "%s: no paths specified (use --stdin0 or provide paths)\n",
                prog_name);
        return 2;
    }

    /* --- Require root --- */
    if (geteuid() != 0) {
        fprintf(stderr, "%s: must run as root\n", prog_name);
        return 2;
    }

    /* --- Resolve the root directory --- */
    char root_resolved[PATH_MAX];
    if (!realpath(root_arg, root_resolved)) {
        fprintf(stderr, "%s: cannot resolve root '%s': %s\n",
                prog_name, root_arg, strerror(errno));
        return 2;
    }

    /* Verify root is a directory */
    struct stat root_st;
    if (stat(root_resolved, &root_st) < 0 || !S_ISDIR(root_st.st_mode)) {
        fprintf(stderr, "%s: root '%s' is not a directory\n",
                prog_name, root_resolved);
        return 2;
    }

    size_t root_resolved_len = strlen(root_resolved);

    /* Strip trailing slash (if any) for consistent prefix matching */
    while (root_resolved_len > 1 && root_resolved[root_resolved_len - 1] == '/') {
        root_resolved[--root_resolved_len] = '\0';
    }

    /* Open root as our anchor fd */
    int root_fd = open(root_resolved, O_PATH | O_DIRECTORY);
    if (root_fd < 0) {
        fprintf(stderr, "%s: cannot open root '%s': %s\n",
                prog_name, root_resolved, strerror(errno));
        return 2;
    }

    if (opt_verbose) {
        fprintf(stderr, "%s: root=%s openat2=%s dry_run=%d\n",
                prog_name, root_resolved,
                have_openat2 < 0 ? "untested" :
                have_openat2 ? "yes" : "no",
                opt_dry_run);
    }

    /* --- Process paths --- */
    int failures = 0;

    if (opt_stdin0) {
        failures = process_stdin0(root_fd, root_resolved, root_resolved_len);
    }

    if (first_path_arg >= 0) {
        for (int i = first_path_arg; i < argc; i++) {
            if (process_path(root_fd, argv[i], root_resolved, root_resolved_len) < 0)
                failures++;
        }
    }

    close(root_fd);

    if (opt_verbose) {
        fprintf(stderr, "%s: done, failures=%d, openat2=%s\n",
                prog_name, failures,
                have_openat2 == 1 ? "yes" : "fallback");
    }

    return failures > 0 ? 1 : 0;
}
