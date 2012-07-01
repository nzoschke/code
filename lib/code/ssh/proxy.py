#!/usr/bin/env python

import base64
import os
import re
import sys
import urllib
from urlparse import urlparse
from twisted.cred.error import UnauthorizedLogin
from twisted.internet import reactor
from twisted.python import failure, log
from twisted.web.client import Agent
from twisted.web.http_headers import Headers

from code.ssh import base

class Server(base.Server):
    ACL = {
        "25:25:85:78:31:f7:6e:46:04:9a:08:9b:8a:11:5c:a7": ["code", "gentle-snow-22"]
    }

    def __init__(self):
        super(Server, self).__init__()

    def _cbRequestUsername(self, response, fingerprint):
        print response.code
        if response.code == 200:
            return fingerprint
        else:
            return failure.Failure(UnauthorizedLogin("%s not authorized" % fingerprint))

    def requestUsername(self, key):
        """
        Make a request to the Compiler API to verify that the fingerprint has basic access.
        """
        fingerprint = key.fingerprint()

        url = urlparse(os.environ.get("COMPILER_API_URL"))
        api_key = url.password
        api_url = "%s://%s:%s%s" % (url.scheme, url.hostname, url.port, url.path)

        auth = base64.b64encode("%s:%s" % (urllib.quote(fingerprint), api_key))

        agent = Agent(reactor)
        d = agent.request("GET", api_url,
            Headers({
                "Authorization":    ["Basic %s" % auth],
                "User-Agent":       ["SSH Proxy"]
            }),
          None
        )

        d.addCallback(self._cbRequestUsername, fingerprint)    
        return d

    def validateCommand(self, username, argv):
        fingerprint, repos = username

        # validate `git-upload-pack '/myrepo.git'` cmd
        if len(argv) != 2:
            raise Exception("Invalid command")

        if argv[0] not in ["git-upload-pack", "git-receive-pack"]:
            raise Exception("Invalid command")
            
        m = re.match(r"'/([a-z0-9-]+).git'", argv[1])

        # malformed or non shell safe path
        if not m:
            raise Exception("Invalid path")

        # not in ACL for SSH fingerprint
        if m.group(1) not in repos:
            raise Exception("Invalid path")

    def spawnProcess(self, proto, cmd):
        print self, proto, cmd
        #self.process = reactor.spawnProcess(proto, self.command[0], self.command, env={'SSH_ORIGINAL_COMMAND': cmd, 'PATH': os.environ['PATH'], 'INSTANCE_NAME': os.environ['INSTANCE_NAME']})
