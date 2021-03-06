import base64
import os
import re
from string import Template
import subprocess
import sys
import tempfile
import urllib
from urlparse import urlparse
from twisted.cred.error import UnauthorizedLogin
from twisted.internet import reactor
from twisted.python import failure, log
from twisted.web.client import Agent
from twisted.web.http_headers import Headers

from code.ssh import base

class Server(base.Server):
    def __init__(self):
        super(Server, self).__init__()

        url = urlparse(os.environ.get("DIRECTOR_API_URL"))
        self.api_key = url.password
        self.api_url = "%s://%s" % (url.scheme, url.hostname)
        if url.port:
            self.api_url += ":%s" % url.port
        self.api_url += url.path

    def authHeader(self, username):
        auth = base64.b64encode("%s:%s" % (urllib.quote(username), self.api_key))
        return "Basic %s" % auth

    def _cbRequestUsername(self, response, username):
        if response.code == 200:
            return username
        else:
            return failure.Failure(UnauthorizedLogin("%s not authorized" % username))

    def requestUsername(self, key):
        """
        Make a request to the Compiler API to verify that the fingerprint has basic access.
        """
        username = key.fingerprint()

        agent = Agent(reactor)
        d = agent.request("GET", "%s/ssh-access" % self.api_url,
            Headers({
                "Authorization":    [self.authHeader(username)],
                "User-Agent":       ["SSH Proxy"]
            }),
          None
        )

        d.addCallback(self._cbRequestUsername, username)
        return d

    def spawnProcess(self, proto, username, argv):
        # validate `git-upload-pack '/myrepo.git'` cmd
        if len(argv) != 2:
            raise Exception("Invalid command")

        if argv[0] not in ["git-upload-pack", "git-receive-pack"]:
            raise Exception("Invalid command")

        # check malformed or non shell safe path
        # app name starts with letter, and contains letters, numbers or dashes
        m = re.match(r"^'/([a-z][a-z0-9-]+).git'$", argv[1])
        if not m:
            raise Exception("Invalid path")

        os.environ["API_URL"]       = self.api_url
        os.environ["AUTH_HEADER"]   = self.authHeader(username)
        os.environ["APP"]           = m.group(1)
        session_dir = subprocess.check_output([
            "bin/template", "etc/ssh-proxy-session",
            "API_URL", "AUTH_HEADER", "APP"
        ]).strip()

        argv.insert(0, "./ssh.sh")
        process = reactor.spawnProcess(proto, argv[0], argv,
            env={"PATH": os.environ["PATH"]},
            path=session_dir,
            childFDs={0:"w", 1:"r", 2:"r", 3:2}
        )
