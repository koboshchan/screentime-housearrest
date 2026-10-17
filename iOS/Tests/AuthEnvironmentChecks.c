// Runs the real sanitizer without a caller pin; authorization must fail closed.
#include "../Helper/Auth.c"
#include <assert.h>
int main(void) {
    assert(setenv("STE_UNTRUSTED_ENVIRONMENT", "must disappear", 1) == 0);
    assert(ste_authorize_caller() == 0);
    assert(*_NSGetEnviron() != NULL);
    assert(getenv("STE_UNTRUSTED_ENVIRONMENT") == NULL);
    assert(strcmp(getenv("PATH"), "/usr/bin:/bin") == 0);
    assert(strcmp(getenv("HOME"), "/var/empty") == 0);
    assert(strcmp(getenv("TMPDIR"), "/var/empty") == 0);
    assert(strcmp(getenv("LANG"), "C") == 0);
    size_t count = 0;
    for (char **entry = *_NSGetEnviron(); *entry; ++entry) ++count;
    assert(count == 4);
    puts("PASS real caller-auth environment sanitation and fail-closed denial");
    return 0;
}
