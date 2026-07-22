import socket

import _vmci
import vmci


assert vmci.VMADDR_CID_ANY == 0xFFFFFFFF
assert vmci.VMADDR_PORT_ANY == 0xFFFFFFFF
assert vmci.VMADDR_CID_HOST == 2
assert vmci.SocketType is vmci.socket
assert callable(_vmci.connect_ex)
assert callable(_vmci.raise_socket_error)

for endpoint in ((-1, 1), (1, -1), (0x100000000, 1), (1, 0x100000000)):
    try:
        vmci._endpoint(endpoint)
    except OverflowError:
        pass
    else:
        raise AssertionError(f"invalid endpoint was accepted: {endpoint!r}")

if vmci.is_available():
    family = vmci.address_family()
    cid = vmci.local_cid()
    assert 0 < family <= 0xFFFF
    assert 0 <= cid < vmci.VMADDR_CID_ANY
    with vmci.socket() as listener:
        listener.bind((vmci.VMADDR_CID_ANY, vmci.VMADDR_PORT_ANY))
        listener.listen()
        bound_cid, bound_port = listener.getsockname()
        assert bound_cid == cid
        assert 0 < bound_port < vmci.VMADDR_PORT_ANY
        listener.settimeout(0.05)
        try:
            listener.accept()
        except socket.timeout:
            pass
        else:
            raise AssertionError("an idle VMCI listener did not time out")
    print(f"VMCI provider available: family={family}, cid={cid}")
else:
    try:
        vmci.address_family()
    except OSError:
        pass
    else:
        raise AssertionError("missing VMCI provider did not produce OSError")
    print("VMCI provider unavailable, as expected on a non-VMware runner")

assert _vmci.available() is vmci.is_available()
assert vmci.timeout is socket.timeout
print("VMCI smoke test passed")
