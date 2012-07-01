#!/usr/bin/env python

import os
import re
import sys
from twisted.python import failure, log

from code.ssh import base

class Server(base.Server):
    ACL = {
        "25:25:85:78:31:f7:6e:46:04:9a:08:9b:8a:11:5c:a7": ["code", "gentle-snow-22"]
    }

    def __init__(self):
        super(Server, self).__init__()

    def requestUsername(self, key):
        fingerprint = key.fingerprint()
        repos       = self.ACL[fingerprint]

        if not repos:
            return failure.Failure(UnauthorizedLogin(fingerprint))
        return (fingerprint, repos)

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
