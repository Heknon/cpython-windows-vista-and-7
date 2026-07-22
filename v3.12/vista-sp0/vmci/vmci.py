"""VMware VMCI/vSockets support for the Windows agent.

The compiled ``_vmci`` module handles the VMCI-specific address structure.
The normal Python socket object continues to provide send, recv, timeouts,
makefile, shutdown, and handle lifetime management.
"""

from __future__ import annotations

import select
import socket as _socket
from typing import Any

import _vmci


VMADDR_CID_ANY = _vmci.VMADDR_CID_ANY
VMADDR_PORT_ANY = _vmci.VMADDR_PORT_ANY
VMADDR_CID_HYPERVISOR = _vmci.VMADDR_CID_HYPERVISOR
VMADDR_CID_LOCAL = _vmci.VMADDR_CID_LOCAL
VMADDR_CID_HOST = _vmci.VMADDR_CID_HOST

SOCK_STREAM = _socket.SOCK_STREAM
SOCK_DGRAM = _socket.SOCK_DGRAM
SHUT_RD = _socket.SHUT_RD
SHUT_WR = _socket.SHUT_WR
SHUT_RDWR = _socket.SHUT_RDWR
SOMAXCONN = _socket.SOMAXCONN
timeout = _socket.timeout
error = _socket.error

_PENDING_CONNECT_ERRORS = {10035, 10036, 10037}


def is_available() -> bool:
    """Return whether VMware Tools exposed the Windows VMCI provider."""

    return _vmci.available()


def address_family() -> int:
    """Return the address-family number assigned by the VMCI driver."""

    return _vmci.address_family()


def local_cid() -> int:
    """Return this virtual machine's VMCI context ID."""

    return _vmci.local_cid()


def version() -> int:
    """Return the packed VMware vSockets implementation version."""

    return _vmci.version()


def _endpoint(address: tuple[int, int]) -> tuple[int, int]:
    if not isinstance(address, tuple) or len(address) != 2:
        raise TypeError("a VMCI address must be a (cid, port) tuple")
    cid, port = address
    if not isinstance(cid, int) or not isinstance(port, int):
        raise TypeError("VMCI cid and port must be integers")
    if not 0 <= cid <= 0xFFFFFFFF or not 0 <= port <= 0xFFFFFFFF:
        raise OverflowError("VMCI cid and port must be unsigned 32-bit integers")
    return cid, port


class socket:
    """A VMCI stream socket compatible with RPyC's socket expectations."""

    def __init__(
        self,
        family: int | None = None,
        type: int = SOCK_STREAM,
        proto: int = 0,
        fileno: int | None = None,
    ) -> None:
        vmci_family = address_family() if family is None else family
        if vmci_family != address_family():
            raise ValueError("family is not the current VMCI address family")

        handle = fileno
        if handle is None:
            handle = _vmci.socket(type=type, protocol=proto)
        try:
            self._socket = _socket.socket(
                vmci_family, type, proto, fileno=handle
            )
        except BaseException:
            if fileno is None:
                _vmci.close(handle)
            raise

    @classmethod
    def _from_handle(cls, handle: int, type: int, proto: int) -> "socket":
        try:
            return cls(type=type, proto=proto, fileno=handle)
        except BaseException:
            _vmci.close(handle)
            raise

    @property
    def family(self) -> int:
        return self._socket.family

    @property
    def type(self) -> int:
        return self._socket.type

    @property
    def proto(self) -> int:
        return self._socket.proto

    def fileno(self) -> int:
        return self._socket.fileno()

    def bind(self, address: tuple[int, int]) -> None:
        cid, port = _endpoint(address)
        _vmci.bind(self.fileno(), cid, port)

    def connect(self, address: tuple[int, int]) -> None:
        cid, port = _endpoint(address)
        error_code = _vmci.connect_ex(self.fileno(), cid, port)
        if error_code == 0:
            return

        timeout_value = self.gettimeout()
        if timeout_value == 0.0 or error_code not in _PENDING_CONNECT_ERRORS:
            _vmci.raise_socket_error(error_code)

        _, writable, exceptional = select.select(
            [], [self._socket], [self._socket], timeout_value
        )
        if not writable and not exceptional:
            raise timeout("timed out")

        error_code = self._socket.getsockopt(_socket.SOL_SOCKET, _socket.SO_ERROR)
        if error_code:
            _vmci.raise_socket_error(error_code)

    def connect_ex(self, address: tuple[int, int]) -> int:
        try:
            self.connect(address)
        except timeout:
            return 10060
        except OSError as exc:
            error_code = exc.winerror if exc.winerror is not None else exc.errno
            if error_code is None:
                raise
            return int(error_code)
        return 0

    def accept(self) -> tuple["socket", tuple[int, int]]:
        timeout_value = self.gettimeout()
        if timeout_value is not None:
            readable, _, _ = select.select([self._socket], [], [], timeout_value)
            if not readable:
                raise timeout("timed out")
        handle, peer = _vmci.accept(self.fileno())
        accepted = self._from_handle(handle, self.type, self.proto)
        accepted.settimeout(_socket.getdefaulttimeout())
        return accepted, peer

    def getsockname(self) -> tuple[int, int]:
        return _vmci.getsockname(self.fileno())

    def getpeername(self) -> tuple[int, int]:
        return _vmci.getpeername(self.fileno())

    def close(self) -> None:
        self._socket.close()

    def detach(self) -> int:
        return self._socket.detach()

    def __enter__(self) -> "socket":
        if self.fileno() == -1:
            raise OSError("socket is closed")
        return self

    def __exit__(self, *args: Any) -> None:
        self.close()

    def __getattr__(self, name: str) -> Any:
        return getattr(self._socket, name)


SocketType = socket


def create_connection(
    address: tuple[int, int], timeout: float | None = None
) -> socket:
    result = socket()
    try:
        if timeout is not None:
            result.settimeout(timeout)
        result.connect(address)
        return result
    except BaseException:
        result.close()
        raise
