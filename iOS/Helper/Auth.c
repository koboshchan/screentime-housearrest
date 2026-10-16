// Signed, bundled child helper only. No daemon, socket, shell, or caller-selected path.
// Build with -DSTE_APP_CDHASH=\"40_lowercase_hex_chars\" after signing the app.
// Compile without the pin for fail-closed host validation.
#include <sys/types.h>
#include <sys/stat.h>
#include <unistd.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#include <crt_externs.h>
#include <grp.h>
#include <mach-o/dyld.h>
extern int proc_pidpath(int pid, void *buffer, uint32_t buffersize);
extern int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);
#ifndef STE_APP_CDHASH
#define STE_APP_CDHASH ""
#endif
static int trusted_path(const char *path) {
    char copy[PATH_MAX];
    if (strlcpy(copy,path,sizeof(copy)) >= sizeof(copy) || copy[0] != '/') return 0;
    struct stat st;
    // realpath is called before this; inspect all resolved ancestors.
    for (char *p = copy + 1;;p++) {
        if (*p != '/' && *p != 0) continue;
        char saved = *p; *p = 0;
        if (lstat(copy,&st) || S_ISLNK(st.st_mode) || st.st_uid != 0 || (st.st_mode & 0022)) return 0;
        *p = saved;
        if (!saved) break;
    }
    return 1;
}
int ste_authorize_caller(void) {
    // Do not consume caller-controlled environment in privileged storage operations.
    // dyld/setuid loader protection is still a target-runtime prerequisite.
    *_NSGetEnviron() = NULL;
    if (setenv("PATH", "/usr/bin:/bin", 1) || setenv("HOME", "/var/empty", 1) ||
        setenv("TMPDIR", "/var/empty", 1) || setenv("LANG", "C", 1)) return 0;
    umask(0077);
    if (geteuid() != 0 || setgroups(0, NULL) || setgid(0) || setuid(0) ||
        getuid() != 0 || geteuid() != 0 || getegid() != 0 ||
        strlen(STE_APP_CDHASH) != 40) return 0;
    pid_t parent = getppid();
    if (parent <= 1) return 0;
    char caller[PATH_MAX], resolved[PATH_MAX], self[PATH_MAX], resolved_self[PATH_MAX];
    uint32_t size = sizeof(self);
    if (_NSGetExecutablePath(self,&size) || !realpath(self,resolved_self)) return 0;
    if (proc_pidpath(parent,caller,sizeof(caller)) <= 0 || !realpath(caller,resolved)) return 0;
    char *slash = strrchr(resolved_self,'/');
    if (!slash || strcmp(slash+1,"stehelper")) return 0;
    *slash = 0;
    char expected[PATH_MAX];
    if (snprintf(expected,sizeof(expected),"%s/ScreenTimeEditor",resolved_self) >= sizeof(expected)) return 0;
    if (strcmp(expected,resolved) || !trusted_path(resolved) || !trusted_path(self)) return 0;
    uint8_t hash[20], second[20]; uint32_t flags = 0;
    if (csops(parent,0,&flags,sizeof(flags)) || !(flags & 1) || csops(parent,5,hash,sizeof(hash))) return 0;
    char hex[41];
    for (int i=0;i<20;i++) snprintf(hex+i*2,3,"%02x",hash[i]);
    if (strcmp(hex,STE_APP_CDHASH)) return 0;
    // Recheck identity after pathname checks; never authorize a changed parent.
    if (parent != getppid() || csops(parent,5,second,sizeof(second)) || memcmp(hash,second,20)) return 0;
    return 1;
}
