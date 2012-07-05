import base64
import os
import re
from string import Template
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

        url = urlparse(os.environ.get("COMPILER_API_URL"))
        self.api_key = url.password
        self.api_url = "%s://%s:%s%s" % (url.scheme, url.hostname, url.port, url.path)

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
        d = agent.request("GET", self.api_url,
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

        # make session temp dir and write curl/ssh config files
        session_dir = tempfile.mkdtemp()
        template_dir = "etc/session/"
        print session_dir

        settings = {
            "api_url":      self.api_url,
            "auth_header":  self.authHeader(username),
            "path":         m.group(1),
            "session_dir":  session_dir,
        }

        for l in os.listdir(template_dir):
            conf = ""
            src  = os.path.join(template_dir, l)
            dest = os.path.join(session_dir,  l)

            with open(src, "r") as f:
                conf = f.read()
                if src.endswith(".conf"):
                    conf = Template(conf).substitute(settings)

            with open(dest, "w") as f:
                f.write(conf)
                if src.endswith(".sh"):
                    os.chmod(dest, 0700)

        # spawn subprocess wrapper to HTTP request a compiler, then forward
        # child stderr mapped to parent stdout for logging
        argv.insert(0, "./ssh-forward.sh")
        process = reactor.spawnProcess(proto, argv[0], argv,
            env={"PATH": os.environ["PATH"]},
            path=session_dir,
            childFDs={0:"w", 1:"r", 2:2}
        )
