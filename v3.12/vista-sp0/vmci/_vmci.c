#define PY_SSIZE_T_CLEAN
#include "Python.h"

#ifndef _WIN32
#error This extension is only supported on Windows.
#endif

#include <winsock2.h>
#include <windows.h>

#include <limits.h>

#define VMCI_SOCKETS_DEVICE L"\\\\.\\VMCI"
#define VMCI_SOCKETS_VERSION 0x81032058
#define VMCI_SOCKETS_GET_AF_VALUE 0x81032068
#define VMCI_SOCKETS_GET_LOCAL_CID 0x8103206c

#define VMADDR_CID_ANY ((unsigned int)-1)
#define VMADDR_PORT_ANY ((unsigned int)-1)
typedef struct sockaddr_vm {
    unsigned short svm_family;
    unsigned short svm_reserved1;
    unsigned int svm_port;
    unsigned int svm_cid;
    unsigned char svm_zero[4];
} sockaddr_vm;

typedef char sockaddr_vm_must_match_sockaddr[
    sizeof(sockaddr_vm) == sizeof(struct sockaddr) ? 1 : -1
];

static int
vmci_query(DWORD command, unsigned int *value, int report_error)
{
    HANDLE device;
    DWORD bytes_returned = 0;
    DWORD error = ERROR_SUCCESS;
    BOOL ok;

    *value = UINT_MAX;
    device = CreateFileW(VMCI_SOCKETS_DEVICE, GENERIC_READ, 0, NULL,
                         OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (device == INVALID_HANDLE_VALUE) {
        error = GetLastError();
        if (report_error) {
            PyErr_SetFromWindowsErr((int)error);
        }
        return 0;
    }

    ok = DeviceIoControl(device, command, value, (DWORD)sizeof(*value), value,
                         (DWORD)sizeof(*value), &bytes_returned, NULL);
    if (!ok) {
        error = GetLastError();
    }
    CloseHandle(device);

    if (!ok) {
        if (report_error) {
            PyErr_SetFromWindowsErr((int)error);
        }
        return 0;
    }
    if (*value == UINT_MAX) {
        if (report_error) {
            PyErr_SetFromWindowsErr(ERROR_NOT_SUPPORTED);
        }
        return 0;
    }
    return 1;
}

static int
vmci_address_family(void)
{
    unsigned int family;

    if (!vmci_query(VMCI_SOCKETS_GET_AF_VALUE, &family, 1)) {
        return -1;
    }
    if (family > USHRT_MAX) {
        PyErr_SetString(
            PyExc_OSError,
            "the VMCI driver returned an invalid address family");
        return -1;
    }
    return (int)family;
}

static int
parse_socket(PyObject *object, SOCKET *socket_handle)
{
    unsigned long long value = PyLong_AsUnsignedLongLong(object);
    if (value == (unsigned long long)-1 && PyErr_Occurred()) {
        return 0;
    }
    if (value > (unsigned long long)(UINT_PTR)INVALID_SOCKET - 1) {
        PyErr_SetString(PyExc_OverflowError, "socket handle is out of range");
        return 0;
    }
    *socket_handle = (SOCKET)(UINT_PTR)value;
    return 1;
}

static int
parse_uint32(PyObject *object, unsigned int *value, const char *name)
{
    unsigned long long parsed = PyLong_AsUnsignedLongLong(object);
    if (parsed == (unsigned long long)-1 && PyErr_Occurred()) {
        return 0;
    }
    if (parsed > UINT_MAX) {
        PyErr_Format(
            PyExc_OverflowError,
            "%s must fit in an unsigned 32-bit integer", name);
        return 0;
    }
    *value = (unsigned int)parsed;
    return 1;
}

static void
set_socket_error_code(int error)
{
    PyErr_SetExcFromWindowsErr(PyExc_OSError, error);
}

static void
set_socket_error(void)
{
    set_socket_error_code(WSAGetLastError());
}

static PyObject *
vmci_available(PyObject *Py_UNUSED(module), PyObject *Py_UNUSED(ignored))
{
    unsigned int family;
    if (vmci_query(VMCI_SOCKETS_GET_AF_VALUE, &family, 0)) {
        Py_RETURN_TRUE;
    }
    Py_RETURN_FALSE;
}

static PyObject *
vmci_get_address_family(PyObject *Py_UNUSED(module), PyObject *Py_UNUSED(ignored))
{
    int family = vmci_address_family();
    if (family < 0) {
        return NULL;
    }
    return PyLong_FromLong(family);
}

static PyObject *
vmci_get_local_cid(PyObject *Py_UNUSED(module), PyObject *Py_UNUSED(ignored))
{
    unsigned int cid;
    if (!vmci_query(VMCI_SOCKETS_GET_LOCAL_CID, &cid, 1)) {
        return NULL;
    }
    return PyLong_FromUnsignedLong(cid);
}

static PyObject *
vmci_get_version(PyObject *Py_UNUSED(module), PyObject *Py_UNUSED(ignored))
{
    unsigned int version;
    if (!vmci_query(VMCI_SOCKETS_VERSION, &version, 1)) {
        return NULL;
    }
    return PyLong_FromUnsignedLong(version);
}

static PyObject *
vmci_socket(PyObject *Py_UNUSED(module), PyObject *args, PyObject *kwargs)
{
    static char *keywords[] = {"type", "protocol", NULL};
    int type = SOCK_STREAM;
    int protocol = 0;
    int family;
    SOCKET handle;

    if (!PyArg_ParseTupleAndKeywords(args, kwargs, "|ii:socket", keywords,
                                     &type, &protocol)) {
        return NULL;
    }
    family = vmci_address_family();
    if (family < 0) {
        return NULL;
    }

    Py_BEGIN_ALLOW_THREADS
    handle = WSASocketW(family, type, protocol, NULL, 0, WSA_FLAG_OVERLAPPED);
    Py_END_ALLOW_THREADS
    if (handle == INVALID_SOCKET) {
        set_socket_error();
        return NULL;
    }
    if (!SetHandleInformation((HANDLE)handle, HANDLE_FLAG_INHERIT, 0)) {
        DWORD error = GetLastError();
        closesocket(handle);
        PyErr_SetFromWindowsErr((int)error);
        return NULL;
    }
    return PyLong_FromUnsignedLongLong((unsigned long long)(UINT_PTR)handle);
}

static int
parse_endpoint(PyObject *args, SOCKET *handle, sockaddr_vm *address)
{
    PyObject *handle_object;
    PyObject *cid_object;
    PyObject *port_object;
    int family;

    if (!PyArg_ParseTuple(args, "OOO", &handle_object, &cid_object, &port_object)) {
        return 0;
    }
    if (!parse_socket(handle_object, handle)) {
        return 0;
    }
    family = vmci_address_family();
    if (family < 0) {
        return 0;
    }
    ZeroMemory(address, sizeof(*address));
    address->svm_family = (unsigned short)family;
    if (!parse_uint32(port_object, &address->svm_port, "port") ||
        !parse_uint32(cid_object, &address->svm_cid, "cid")) {
        return 0;
    }
    return 1;
}

static PyObject *
vmci_bind(PyObject *Py_UNUSED(module), PyObject *args)
{
    SOCKET handle;
    sockaddr_vm address;
    int result;

    if (!parse_endpoint(args, &handle, &address)) {
        return NULL;
    }
    Py_BEGIN_ALLOW_THREADS
    result = bind(handle, (struct sockaddr *)&address, (int)sizeof(address));
    Py_END_ALLOW_THREADS
    if (result == SOCKET_ERROR) {
        set_socket_error();
        return NULL;
    }
    Py_RETURN_NONE;
}

static PyObject *
vmci_connect(PyObject *Py_UNUSED(module), PyObject *args)
{
    SOCKET handle;
    sockaddr_vm address;
    int result;

    if (!parse_endpoint(args, &handle, &address)) {
        return NULL;
    }
    Py_BEGIN_ALLOW_THREADS
    result = connect(
        handle, (struct sockaddr *)&address, (int)sizeof(address));
    Py_END_ALLOW_THREADS
    if (result == SOCKET_ERROR) {
        set_socket_error();
        return NULL;
    }
    Py_RETURN_NONE;
}

static PyObject *
vmci_connect_ex(PyObject *Py_UNUSED(module), PyObject *args)
{
    SOCKET handle;
    sockaddr_vm address;
    int result;
    int error = 0;

    if (!parse_endpoint(args, &handle, &address)) {
        return NULL;
    }
    Py_BEGIN_ALLOW_THREADS
    result = connect(
        handle, (struct sockaddr *)&address, (int)sizeof(address));
    if (result == SOCKET_ERROR) {
        error = WSAGetLastError();
    }
    Py_END_ALLOW_THREADS
    return PyLong_FromLong(error);
}

static PyObject *
vmci_raise_socket_error(PyObject *Py_UNUSED(module), PyObject *argument)
{
    long error = PyLong_AsLong(argument);
    if (error == -1 && PyErr_Occurred()) {
        return NULL;
    }
    if (error < 0 || error > INT_MAX) {
        PyErr_SetString(PyExc_ValueError, "socket error must be a positive int");
        return NULL;
    }
    set_socket_error_code((int)error);
    return NULL;
}

static PyObject *
endpoint_tuple(const sockaddr_vm *address, int address_length)
{
    if (address_length < (int)sizeof(sockaddr_vm)) {
        PyErr_SetString(PyExc_OSError, "Winsock returned a truncated VMCI address");
        return NULL;
    }
    return Py_BuildValue("(II)", address->svm_cid, address->svm_port);
}

static PyObject *
vmci_accept(PyObject *Py_UNUSED(module), PyObject *argument)
{
    SOCKET listener;
    SOCKET accepted;
    sockaddr_vm address;
    int address_length = (int)sizeof(address);
    PyObject *endpoint;
    PyObject *result;

    if (!parse_socket(argument, &listener)) {
        return NULL;
    }
    ZeroMemory(&address, sizeof(address));
    Py_BEGIN_ALLOW_THREADS
    accepted = accept(listener, (struct sockaddr *)&address, &address_length);
    Py_END_ALLOW_THREADS
    if (accepted == INVALID_SOCKET) {
        set_socket_error();
        return NULL;
    }
    if (!SetHandleInformation((HANDLE)accepted, HANDLE_FLAG_INHERIT, 0)) {
        DWORD error = GetLastError();
        closesocket(accepted);
        PyErr_SetFromWindowsErr((int)error);
        return NULL;
    }

    endpoint = endpoint_tuple(&address, address_length);
    if (endpoint == NULL) {
        closesocket(accepted);
        return NULL;
    }
    {
        PyObject *handle_object = PyLong_FromUnsignedLongLong(
            (unsigned long long)(UINT_PTR)accepted);
        if (handle_object == NULL) {
            Py_DECREF(endpoint);
            closesocket(accepted);
            return NULL;
        }
        result = PyTuple_Pack(2, handle_object, endpoint);
        Py_DECREF(handle_object);
        Py_DECREF(endpoint);
    }
    if (result == NULL) {
        closesocket(accepted);
    }
    return result;
}

typedef int (WSAAPI *name_function)(SOCKET, struct sockaddr *, int *);

static PyObject *
vmci_socket_name(PyObject *argument, name_function function)
{
    SOCKET handle;
    sockaddr_vm address;
    int address_length = (int)sizeof(address);
    int result;

    if (!parse_socket(argument, &handle)) {
        return NULL;
    }
    ZeroMemory(&address, sizeof(address));
    Py_BEGIN_ALLOW_THREADS
    result = function(handle, (struct sockaddr *)&address, &address_length);
    Py_END_ALLOW_THREADS
    if (result == SOCKET_ERROR) {
        set_socket_error();
        return NULL;
    }
    return endpoint_tuple(&address, address_length);
}

static PyObject *
vmci_getsockname(PyObject *Py_UNUSED(module), PyObject *argument)
{
    return vmci_socket_name(argument, getsockname);
}

static PyObject *
vmci_getpeername(PyObject *Py_UNUSED(module), PyObject *argument)
{
    return vmci_socket_name(argument, getpeername);
}

static PyObject *
vmci_close(PyObject *Py_UNUSED(module), PyObject *argument)
{
    SOCKET handle;
    int result;

    if (!parse_socket(argument, &handle)) {
        return NULL;
    }
    Py_BEGIN_ALLOW_THREADS
    result = closesocket(handle);
    Py_END_ALLOW_THREADS
    if (result == SOCKET_ERROR) {
        set_socket_error();
        return NULL;
    }
    Py_RETURN_NONE;
}

static PyMethodDef vmci_methods[] = {
    {"available", vmci_available, METH_NOARGS,
     "Return whether the VMware VMCI vSockets provider is available."},
    {"address_family", vmci_get_address_family, METH_NOARGS,
     "Return the dynamically assigned Windows VMCI address family."},
    {"local_cid", vmci_get_local_cid, METH_NOARGS,
     "Return this VM's VMCI context ID."},
    {"version", vmci_get_version, METH_NOARGS,
     "Return the packed VMware vSockets version."},
    {"socket", _PyCFunction_CAST(vmci_socket), METH_VARARGS | METH_KEYWORDS,
     "Create a VMCI socket and return its native Winsock handle."},
    {"bind", vmci_bind, METH_VARARGS,
     "Bind a socket handle to a (cid, port) endpoint."},
    {"connect", vmci_connect, METH_VARARGS,
     "Connect a socket handle to a (cid, port) endpoint."},
    {"connect_ex", vmci_connect_ex, METH_VARARGS,
     "Connect a socket handle and return its Winsock error code."},
    {"raise_socket_error", vmci_raise_socket_error, METH_O,
     "Raise OSError for a Winsock error code."},
    {"accept", vmci_accept, METH_O,
     "Accept a connection and return (socket_handle, (cid, port))."},
    {"getsockname", vmci_getsockname, METH_O,
     "Return a socket handle's local (cid, port)."},
    {"getpeername", vmci_getpeername, METH_O,
     "Return a socket handle's peer (cid, port)."},
    {"close", vmci_close, METH_O,
     "Close a native socket handle not owned by a Python socket object."},
    {NULL, NULL, 0, NULL}
};

static int
vmci_module_exec(PyObject *module)
{
    WSADATA data;
    int error = WSAStartup(MAKEWORD(2, 2), &data);
    if (error != 0) {
        PyErr_SetExcFromWindowsErr(PyExc_OSError, error);
        return -1;
    }

#define ADD_UINT(name, value) do { \
    PyObject *constant = PyLong_FromUnsignedLong((unsigned long)(value)); \
    if (constant == NULL || PyModule_AddObject(module, name, constant) < 0) { \
        Py_XDECREF(constant); \
        return -1; \
    } \
} while (0)
    ADD_UINT("VMADDR_CID_ANY", VMADDR_CID_ANY);
    ADD_UINT("VMADDR_PORT_ANY", VMADDR_PORT_ANY);
    ADD_UINT("VMADDR_CID_HYPERVISOR", 0);
    ADD_UINT("VMADDR_CID_LOCAL", 1);
    ADD_UINT("VMADDR_CID_HOST", 2);
    ADD_UINT("SOCK_STREAM", SOCK_STREAM);
    ADD_UINT("SOCK_DGRAM", SOCK_DGRAM);
#undef ADD_UINT
    return 0;
}

static void
vmci_module_free(void *Py_UNUSED(module))
{
    WSACleanup();
}

static PyModuleDef_Slot vmci_slots[] = {
    {Py_mod_exec, vmci_module_exec},
    {0, NULL}
};

static struct PyModuleDef vmci_module = {
    PyModuleDef_HEAD_INIT,
    "_vmci",
    "Low-level Windows VMware VMCI vSockets support.",
    0,
    vmci_methods,
    vmci_slots,
    NULL,
    NULL,
    vmci_module_free
};

PyMODINIT_FUNC
PyInit__vmci(void)
{
    return PyModuleDef_Init(&vmci_module);
}
