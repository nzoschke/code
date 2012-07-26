import os
import socket
import subprocess
import sys
import urllib
from twisted.conch.ssh import keys
from twisted.cred.error import UnauthorizedLogin
from twisted.internet import reactor
from twisted.python import failure, log
from twisted.web.client import Agent
from twisted.web.http_headers import Headers

from code.ssh import base

class Server(base.Server):
    def __init__(self):
        super(Server, self).__init__()

        self.callback_url = os.environ["CALLBACK_URL"]
        self.hostname     = socket.gethostbyname(socket.gethostname())
        self.port         = os.environ["PORT"]
        self.ssh_pub_key  = os.environ["SSH_PUB_KEY"]

    def _cbOnStart(self, response):
        if response.code != 200:
            raise Exception("Invalid session")

    def onStart(self):
        qs = urllib.urlencode({
            "hostname": self.hostname,
            "port":     self.port,
        })

        agent = Agent(reactor)
        url = "%s?%s" % (self.callback_url, qs)
        d = agent.request("PUT", url,
            Headers({
                "User-Agent": ["SSH Compiler"]
            }),
          None
        )

        d.addCallback(self._cbOnStart)
        return d

    def requestUsername(self, key):
        if keys.Key.fromString(data=self.ssh_pub_key) == key:
          return key.fingerprint()
        else:
            return failure.Failure(UnauthorizedLogin("Not authorized"))

    def spawnProcess(self, proto, username, argv):
        session_dir = subprocess.check_output([
            "bin/template", "etc/compiler-session",
            "CACHE_GET_URL", "CACHE_PUT_URL", "CALLBACK_URL", "REPO_GET_URL", "REPO_PUT_URL"
        ]).strip()

        argv.insert(0, "./git-receive-pack.sh")
        process = reactor.spawnProcess(proto, argv[0], argv,
            env=os.environ,
            path=session_dir,
            childFDs={0:"w", 1:"r", 2:"r", 3:2}
        )

    def onClose(self):
        reactor.stop()