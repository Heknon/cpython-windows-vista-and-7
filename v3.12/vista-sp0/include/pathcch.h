#pragma once

#include <windows.h>

#ifndef PATHCCH_ALLOW_LONG_PATHS
#define PATHCCH_ALLOW_LONG_PATHS 0x00000001
#endif

#ifndef LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR
#define LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR 0x00000100
#define LOAD_LIBRARY_SEARCH_APPLICATION_DIR 0x00000200
#define LOAD_LIBRARY_SEARCH_USER_DIRS 0x00000400
#define LOAD_LIBRARY_SEARCH_SYSTEM32 0x00000800
#define LOAD_LIBRARY_SEARCH_DEFAULT_DIRS 0x00001000
#endif

#ifdef __cplusplus
extern "C" {
#endif

HRESULT WINAPI PathCchCombineEx(
    PWSTR path_out,
    size_t path_out_count,
    PCWSTR path_in,
    PCWSTR more,
    ULONG flags
);
HRESULT WINAPI PathCchRemoveFileSpec(PWSTR path, size_t path_count);
HRESULT WINAPI PathCchSkipRoot(PCWSTR path, PCWSTR *root_end);

#ifdef __cplusplus
}
#endif

#ifdef PY_VISTA_LEGACY_SDK
typedef PVOID DLL_DIRECTORY_COOKIE;

typedef struct _FILE_ID_128 {
    BYTE Identifier[16];
} FILE_ID_128;

typedef struct _FILE_ID_INFO {
    ULONGLONG VolumeSerialNumber;
    FILE_ID_128 FileId;
} FILE_ID_INFO;

#define FileIdInfo ((FILE_INFO_BY_HANDLE_CLASS)18)

#ifndef FILE_DEVICE_CONSOLE
#define FILE_DEVICE_CONSOLE 0x00000050
#endif
#endif
