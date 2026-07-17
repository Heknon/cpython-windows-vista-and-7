@(
    # This is deliberately a DLL-name allowlist, not an export allowlist.
    # It only permits system DLLs that shipped in Vista RTM. Exact imported
    # symbols still require validation against exports captured from an RTM VM.
    "ADVAPI32.DLL"
    "BCRYPT.DLL"
    "CABINET.DLL"
    "CRYPT32.DLL"
    "IPHLPAPI.DLL"
    "KERNEL32.DLL"
    "MSI.DLL"
    "OLE32.DLL"
    "OLEAUT32.DLL"
    "PROPSYS.DLL"
    "RPCRT4.DLL"
    "USER32.DLL"
    "VERSION.DLL"
    "WINMM.DLL"
    "WS2_32.DLL"
)