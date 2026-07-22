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


def stream_round_trip(listener, client, cid, any_cid, any_port):
    listener.bind((any_cid, any_port))
    listener.listen()
    listener.settimeout(5.0)
    bound_cid, bound_port = listener.getsockname()
    assert bound_cid == cid
    assert 0 < bound_port < any_port

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
    with vmci.socket() as listener, vmci.socket() as client:
        listener.settimeout(0.05)
        listener.bind((vmci.VMADDR_CID_ANY, vmci.VMADDR_PORT_ANY))
        listener.listen()
        try:
            listener.accept()
        except socket.timeout:
            pass
        else:
            raise AssertionError("an idle VMCI listener did not time out")
    with vmci.socket() as listener, vmci.socket() as client:
        stream_round_trip(
            listener,
            client,
            cid,
            vmci.VMADDR_CID_ANY,
            vmci.VMADDR_PORT_ANY,
        )
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
    assert socket.vmci_available()
    assert socket.AF_VMCI == family
    assert socket.AF_VSOCK == family
    assert socket.vmci_address_family() == family
    assert socket.vmci_local_cid() == cid
    with (
        socket.socket(socket.AF_VMCI, socket.SOCK_STREAM) as listener,
        socket.socket(socket.AF_VMCI, socket.SOCK_STREAM) as client,
    ):
        stream_round_trip(
            listener,
            client,
            cid,
            socket.VMADDR_CID_ANY,
            socket.VMADDR_PORT_ANY,
        )

    for endpoint in (
        (-1, 1),
        (1, -1),
        (0x100000000, 1),
        (1, 0x100000000),
    ):
        with socket.socket(socket.AF_VMCI, socket.SOCK_STREAM) as probe:
            try:
                probe.bind(endpoint)
            except OverflowError:
                pass
            else:
                raise AssertionError(
                    f"native socket accepted invalid endpoint: {endpoint!r}"
                )

    with (
        socket.socket(socket.AF_VMCI, socket.SOCK_STREAM) as listener,
        socket.socket(socket.AF_VMCI, socket.SOCK_STREAM) as client,
    ):
        listener.bind((socket.VMADDR_CID_ANY, socket.VMADDR_PORT_ANY))
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

    with (
        socket.socket(socket.AF_VMCI, socket.SOCK_DGRAM) as sender,
        socket.socket(socket.AF_VMCI, socket.SOCK_DGRAM) as receiver,
    ):
        sender.bind((socket.VMADDR_CID_ANY, socket.VMADDR_PORT_ANY))
        receiver.bind((socket.VMADDR_CID_ANY, socket.VMADDR_PORT_ANY))
        receiver.settimeout(5.0)
        sender.sendto(b"vmci-datagram", receiver.getsockname())
        payload, peer = receiver.recvfrom(64)
        assert payload == b"vmci-datagram"
        assert peer[0] == cid
    print(f"VMCI provider available: family={family}, cid={cid}")
else:
    assert not socket.vmci_available()
    assert not hasattr(socket, "AF_VMCI")
    assert not hasattr(socket, "AF_VSOCK")
    try:
        vmci.address_family()
    except OSError:
        pass
    else:
        raise AssertionError("missing VMCI provider did not produce OSError")
    print("VMCI provider unavailable, as expected on a non-VMware runner")

assert _vmci.available() is vmci.is_available()
assert vmci.timeout is socket.timeout
assert socket.VMADDR_CID_ANY == vmci.VMADDR_CID_ANY
assert socket.VMADDR_PORT_ANY == vmci.VMADDR_PORT_ANY
assert socket.VMADDR_CID_HOST == vmci.VMADDR_CID_HOST
print("VMCI smoke test passed")
