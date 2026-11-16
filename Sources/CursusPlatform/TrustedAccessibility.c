#include "CursusPlatform.h"
#include <ApplicationServices/ApplicationServices.h>
#include <pthread.h>
#include <libproc.h>
#include <unistd.h>

// The SDK exports the option as a C global. Keep its access on the main thread
// without declaring native event objects Sendable or disabling Swift checks.
bool CursusRequestAccessibilityTrust(void) {
    if (!pthread_main_np()) return false;
    const void *keys[] = { kAXTrustedCheckOptionPrompt };
    const void *values[] = { kCFBooleanTrue };
    CFDictionaryRef options = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    if (!options) return false;
    bool trusted = AXIsProcessTrustedWithOptions(options);
    CFRelease(options);
    return trusted;
}

bool CursusProcessSameUser(int32_t pid) {
    struct proc_bsdinfo info = {0};
    int bytes = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info));
    return bytes == sizeof(info) && info.pbi_uid == geteuid() && info.pbi_ruid == getuid();
}
