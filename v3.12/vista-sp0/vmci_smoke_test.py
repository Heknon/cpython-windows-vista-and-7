import select
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


def stream_round_trip(listener, client, cid):
    listener.bind((vmci.VMADDR_CID_ANY, vmci.VMADDR_PORT_ANY))
    listener.listen()
    listener.settimeout(5.0)
    bound_cid, bound_port = listener.getsockname()
    assert bound_cid == cid
    assert 0 < bound_port < vmci.VMADDR_PORT_ANY

    client.settimeout(5.0)
    assert client.connect_ex((cid, bound_port)) == 0
    connection, peer = listener.accept()
    with connection:
        connection.settimeout(5.0)
        assert peer[0] == cid
        client.sendall(b"vmci-client")
        assert connection.recv(64) == b"vmci-client"
        connection.sendall(b"vmci-server")
        assert client.recv(64) == b"vmci-server"

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
    with vmci.socket() as listener, vmci.socket() as client:
        stream_round_trip(listener, client, cid)
    with vmci.socket() as listener, vmci.socket() as client:
        listener.bind((vmci.VMADDR_CID_ANY, vmci.VMADDR_PORT_ANY))
        listener.listen()
        listener.settimeout(5.0)
        _, port = listener.getsockname()
        client.setblocking(False)
        result = client.connect_ex((cid, port))
        assert result in (0, 10035, 10036, 10037)
        if result:
            _, writable, exceptional = select.select([], [client], [client], 5.0)
            assert writable or exceptional
            assert client.getsockopt(socket.SOL_SOCKET, socket.SO_ERROR) == 0
        connection, _ = listener.accept()
        connection.close()
    for _ in range(3):
        with vmci.socket() as listener:
            listener.bind((vmci.VMADDR_CID_ANY, vmci.VMADDR_PORT_ANY))
            listener.listen()
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
