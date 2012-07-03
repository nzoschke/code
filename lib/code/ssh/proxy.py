#!/usr/bin/env python

import base64
import os
import re
import sys
import urllib
import urllib2
from urlparse import urlparse
from twisted.cred.error import UnauthorizedLogin
from twisted.internet import defer, reactor
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

        url = urlparse(os.environ.get("COMPILER_API_URL"))
        self.api_key = url.password
        self.api_url = "%s://%s:%s%s" % (url.scheme, url.hostname, url.port, url.path)

    def authHeader(self, fingerprint):
        auth = base64.b64encode("%s:%s" % (urllib.quote(fingerprint), self.api_key))
        return "Basic %s" % auth

    def _cbRequestUsername(self, response, fingerprint):
        if response.code == 200:
            return fingerprint
        else:
            return failure.Failure(UnauthorizedLogin("%s not authorized" % fingerprint))

    def requestUsername(self, key):
        """
        Make a request to the Compiler API to verify that the fingerprint has basic access.
        """
        fingerprint = key.fingerprint()

        agent = Agent(reactor)
        d = agent.request("GET", self.api_url,
            Headers({
                "Authorization":    [self.authHeader(fingerprint)],
                "User-Agent":       ["SSH Proxy"]
            }),
          None
        )

        d.addCallback(self._cbRequestUsername, fingerprint)
        return d

    def spawnProcess(self, proto, username, argv):
        # validate `git-upload-pack '/myrepo.git'` cmd
        if len(argv) != 2:
            raise Exception("Invalid command")

        if argv[0] not in ["git-upload-pack", "git-receive-pack"]:
            raise Exception("Invalid command")

        # check malformed or non shell safe path            
        m = re.match(r"^'/([a-z0-9-]+).git'$", argv[1])
        if not m:
            raise Exception("Invalid path")

        # TODO: implement non-blocking request
        repository = m.group(1)
        req = urllib2.Request(
            "%s/%s" % (self.api_url, repository),
            "{}",
            {"Authorization": self.authHeader(username)}
        )

        try:
            response = urllib2.urlopen(req)
        except urllib2.HTTPError, e:
            print "codon ssh-proxy fn=spawnProcess at=error username=%s argv=\"%s\" code=%i" % (username, " ".join(argv), e.code)
            raise Exception("Invalid path")

        process = reactor.spawnProcess(proto, argv[0], argv, env={
            "SSH_ORIGINAL_COMMAND": " ".join(argv), 
            "PATH":                 os.environ["PATH"]
        })
        print "codon ssh-proxy fn=spawnProcess username=%s argv=\"%s\" pid=%i" % (username, " ".join(argv), process.pid)
