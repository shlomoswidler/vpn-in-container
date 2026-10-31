#!/usr/bin/env python3
"""Forward each TCP connection on 127.0.0.1:PORT to a new COMMAND's stdin and stdout.

tests/browser/run.sh reaches the web UI of a container that has no network (--network
none) this way, with COMMAND `docker exec -i CONTAINER nc -N 127.0.0.1 5800`: the browser
on the host loads the page, and opens its WebSockets, through 127.0.0.1:PORT. Bytes are
copied unchanged both ways. When the client stops sending, COMMAND's stdin is closed; when
COMMAND's stdout ends, the client's connection is shut down for writing; once both are done
the connection is closed and COMMAND, if still running, is killed.

Prints "listening on 127.0.0.1:PORT" once it accepts connections (PORT 0 picks a free one).
Usage: tunnel.py PORT COMMAND...
"""

import socket
import subprocess
import sys
import threading

CHUNK = 65536


def client_to_command(connection: socket.socket, stdin) -> None:
    try:
        while data := connection.recv(CHUNK):
            stdin.write(data)
            stdin.flush()
    except OSError:
        pass
    finally:
        try:
            stdin.close()
        except OSError:
            pass


def command_to_client(stdout, connection: socket.socket) -> None:
    try:
        while data := stdout.read1(CHUNK):
            connection.sendall(data)
        connection.shutdown(socket.SHUT_WR)
    except OSError:
        pass


def handle(connection: socket.socket, command: list[str]) -> None:
    with connection:
        process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        pumps = [
            threading.Thread(target=client_to_command, args=(connection, process.stdin)),
            threading.Thread(target=command_to_client, args=(process.stdout, connection)),
        ]
        for pump in pumps:
            pump.start()
        for pump in pumps:
            pump.join()
        if process.poll() is None:
            process.kill()
        process.wait()
        process.stdout.close()


def serve(listener: socket.socket, command: list[str]) -> None:
    while True:
        connection, _ = listener.accept()
        threading.Thread(target=handle, args=(connection, command), daemon=True).start()


def main(argv: list[str]) -> int:
    if len(argv) < 2 or not argv[0].isdigit():
        print(__doc__, file=sys.stderr)
        return 2
    with socket.create_server(("127.0.0.1", int(argv[0]))) as listener:
        print(f"listening on 127.0.0.1:{listener.getsockname()[1]}", flush=True)
        serve(listener, argv[1:])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
