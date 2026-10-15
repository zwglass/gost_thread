"""Exercise direct mode without real miners, systemd, or network downloads."""
import os
from pathlib import Path
import shlex
import socket
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory() as tmp:
    directory = Path(tmp)
    def executable(name, body):
        path = directory / name
        path.write_text(body)
        path.chmod(0o755)
        return str(path)
    executable('timeout', '#!/usr/bin/env python3\nimport subprocess,sys\ntry: sys.exit(subprocess.call(sys.argv[2:], timeout=float(sys.argv[1])))\nexcept subprocess.TimeoutExpired: sys.exit(124)\n')
    executable('systemctl', '#!/bin/sh\ntouch "' + tmp + '/systemctl-called"\nexit 99\n')
    gost = executable('gost', '#!/usr/bin/env python3\nimport socket,sys\na=sys.argv[1].split("://")[1].split("/")[0]\nh,p=a.rsplit(":",1)\ns=socket.socket();s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1);s.bind((h,int(p)));s.listen()\nwhile True:\n c,_=s.accept();c.close()\n')
    miner = executable('miner', '#!/usr/bin/env python3\nimport sys\nfrom pathlib import Path\nPath(' + repr(tmp + '/args') + ').write_text(repr(sys.argv[1:]))\n')
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        port = listener.getsockname()[1]
    client = f'GOST_BIN={shlex.quote(gost)}\nLOCAL_FORWARD=tcp://127.0.0.1:{port}/pool:1234\nREMOTE_RELAY=relay+tls://example:8443\n'
    runtime = f'MINER_BIN={shlex.quote(miner)}\nMINER_WORKDIR={shlex.quote(tmp)}\nMINER_POOL=tcp://127.0.0.1:{port}\nMINER_ARG_COUNT=2\nMINER_ARG_0={shlex.quote("space ; $(literal)")}\nMINER_ARG_1=\x27\x27\n'
    (directory / 'client.env').write_text(client)
    (directory / 'miner.env').write_text(runtime)
    env = dict(os.environ, PATH=tmp + ':' + os.environ['PATH'], GOST_THREAD_CONFIG_DIR=tmp)
    command = [str(ROOT / 'scripts/run_pearl_miners_direct.sh')]
    subprocess.run(command, env=env, check=True, timeout=15)
    assert (directory / 'args').read_text() == repr(['space ; $(literal)', ''])
    assert (directory / 'client.env').read_text() == client
    assert (directory / 'miner.env').read_text() == runtime
    with socket.socket() as listener:
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind(('127.0.0.1', port))
        listener.listen()
        result = subprocess.run(command, env=env, timeout=10, capture_output=True)
        assert result.returncode != 0 and b'already in use' in result.stdout
        listener.settimeout(2)
        connection, _ = listener.accept()
        connection.close()
    assert not (directory / 'systemctl-called').exists()
print('Direct runner tests passed.')
