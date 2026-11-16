#ifndef CURSUS_PLATFORM_H
#define CURSUS_PLATFORM_H
#include <stdbool.h>
#include <stdint.h>
bool CursusRequestAccessibilityTrust(void);
bool CursusProcessSameUser(int32_t pid);
#endif
