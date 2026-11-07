#!/usr/bin/env python3
"""Real loopback FTP server for integration tests; requires pyftpdlib 2.2.0."""
import logging
import os
from pathlib import Path
import sys
from pyftpdlib.authorizers import DummyAuthorizer
from pyftpdlib.handlers import FTPHandler, ThrottledDTPHandler
from pyftpdlib.servers import FTPServer

logging.disable(logging.CRITICAL)
root = Path(sys.argv[1])
mode = sys.argv[2]
filesystem = root / ("files-" + mode)
home = filesystem / "home"
home.mkdir(parents=True)
for name in ("sub folder", "empty", "denied", "no-mlsd", "slow", "upload-denied"):
    (home / name).mkdir()
(home / "hello ü #%.txt").write_text("hello FTP", encoding="utf-8")
(home / ".hidden").write_text("hidden", encoding="utf-8")
(home / "sub folder" / "nested.txt").write_text("nested", encoding="utf-8")
authorizer = DummyAuthorizer()
authorizer.add_user("ftp-user", os.environ["BASEDFTP_FTP_TEST_PASSWORD"], str(filesystem), perm="elradfw")

authorizer.add_user("ftp-queue", "", str(filesystem), perm="elradfw")
class TestDataHandler(ThrottledDTPHandler):
    read_limit = 512 * 1024
    write_limit = 512 * 1024

class Handler(FTPHandler):
    dtp_handler = TestDataHandler
    def on_file_received(self, file):
        self.record_finished(file)
    def on_incomplete_file_received(self, file):
        self.record_finished(file)
    def record_finished(self, file):
        with (root / ("finished-" + mode)).open("a") as log:
            log.write(Path(file).name + "\n")
    def ftp_STOR(self, path, mode="w"):
        if Path(path).parent.name == "upload-denied":
            self.respond("550 Upload denied for test")
        else:
            super().ftp_STOR(path, mode)
    def ftp_RNTO(self, path):
        if Path(path).name == "commit-denied":
            self.respond("550 Rename denied for test")
        else:
            super().ftp_RNTO(path)

    auth_failed_timeout = 0
    def on_login(self, username):
        self.fs.cwd = "/home"
    def ftp_EPSV(self, line):
        if mode == "pasv":
            self.respond("502 EPSV disabled for PASV fallback test")
        else:
            super().ftp_EPSV(line)
    def ftp_MLSD(self, path):
        name = Path(path).name
        if name == "denied":
            self.respond("550 Directory access denied")
        elif name == "no-mlsd":
            self.respond("500 MLSD unavailable")
        elif name == "slow":
            # Keep the control loop responsive while withholding the listing reply.
            self.ioloop.call_later(10, lambda: self.respond("451 Delayed test response") if self.connected else None)
        else:
            super().ftp_MLSD(path)
    def log_cmd(self, cmd, arg, respcode, respstr):
        # Record command names only, never credentials or request arguments.
        with (root / ("commands-" + mode)).open("a") as file:
            file.write(cmd + "\n")

Handler.authorizer = authorizer
# A bogus advertised PASV address proves clients use the control peer instead.
if mode == "pasv":
    Handler.masquerade_address = "192.0.2.123"
server = FTPServer(("127.0.0.1", 0), Handler)
(root / ("port-" + mode)).write_text(str(server.socket.getsockname()[1]))
server.serve_forever(timeout=0.1)
