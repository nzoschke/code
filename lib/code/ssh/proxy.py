#!/usr/bin/env python

# Copyright (c) Noah Zoschke
# MIT license

from twisted.cred import portal, checkers
from twisted.cred.error import UnauthorizedLogin
from twisted.conch import error, avatar
from twisted.conch.checkers import SSHPublicKeyDatabase
from twisted.conch.ssh import factory, userauth, connection, keys, session
from twisted.internet import reactor, protocol, defer
from twisted.python import components, failure, log
from zope.interface import implements
import os
import re
import shlex
import sys

log.startLogging(sys.stderr)

class Server(object):
    class ExampleFactory(factory.SSHFactory):
        publicKeys = {
            "ssh-rsa": keys.Key.fromString(
                data="ssh-rsa AAAAB3NzaC1yc2EAAAABIwAAAGEArzJx8OYOnJmzf4tfBEvLi8DVPrJ3/c9k2I/Az64fxjHf9imyRJbixtQhlH9lfNjUIx+4LmrJH5QNRsFporcHDKOTwTTYLh5KmRpslkYHRivcJSkbh/C+BR3utDS555mV"
            )
        }
        privateKeys = {
            "ssh-rsa": keys.Key.fromString(
                data="""-----BEGIN RSA PRIVATE KEY-----
    MIIByAIBAAJhAK8ycfDmDpyZs3+LXwRLy4vA1T6yd/3PZNiPwM+uH8Yx3/YpskSW
    4sbUIZR/ZXzY1CMfuC5qyR+UDUbBaaK3Bwyjk8E02C4eSpkabJZGB0Yr3CUpG4fw
    vgUd7rQ0ueeZlQIBIwJgbh+1VZfr7WftK5lu7MHtqE1S1vPWZQYE3+VUn8yJADyb
    Z4fsZaCrzW9lkIqXkE3GIY+ojdhZhkO1gbG0118sIgphwSWKRxK0mvh6ERxKqIt1
    xJEJO74EykXZV4oNJ8sjAjEA3J9r2ZghVhGN6V8DnQrTk24Td0E8hU8AcP0FVP+8
    PQm/g/aXf2QQkQT+omdHVEJrAjEAy0pL0EBH6EVS98evDCBtQw22OZT52qXlAwZ2
    gyTriKFVoqjeEjt3SZKKqXHSApP/AjBLpF99zcJJZRq2abgYlf9lv1chkrWqDHUu
    DZttmYJeEfiFBBavVYIF1dOlZT0G8jMCMBc7sOSZodFnAiryP+Qg9otSBjJ3bQML
    pSTqy7c3a2AScC/YyOwkDaICHnnD3XyjMwIxALRzl0tQEKMXs6hH8ToUdlLROCrP
    EhQ0wahUTCk1gKA4uPD6TMTChavbh4K63OvbKg==
    -----END RSA PRIVATE KEY-----"""
            )
        }

        def startFactory(self):
            factory.SSHFactory.startFactory(self)
            print "AFTER STARTED"

    class RepoACL(SSHPublicKeyDatabase):
        ACL = {
            "25:25:85:78:31:f7:6e:46:04:9a:08:9b:8a:11:5c:a7": ["code", "gentle-snow-22"]
        }

        def requestAvatarId(self, credentials):
            fingerprint = keys.Key.fromString(data=credentials.blob).fingerprint()
            repos       = self.ACL[fingerprint]

            if not repos:
                return failure.Failure(UnauthorizedLogin(fingerprint))
            return (fingerprint, repos)

    class GitRealm:
        implements(portal.IRealm)

        def requestAvatar(self, avatarId, mind, *interfaces):
            return interfaces[0], Server.GitUser(avatarId), lambda: None

    class GitUser(avatar.ConchUser):
        def __init__(self, acl):
            avatar.ConchUser.__init__(self)
            self.fingerprint, self.repos = acl
            self.channelLookup.update({ "session": session.SSHSession })

    class GitSession:    
        def __init__(self, user):
            self.user = user

        def execCommand(self, proto, cmd):
            # validate `git-upload-pack '/myrepo.git'` cmd
            lexer = shlex.shlex(cmd)
            lexer.whitespace_split = True
            argv = [s for s in lexer]

            if len(argv) != 2:
                raise Exception("Invalid command")

            if argv[0] not in ["git-upload-pack", "git-receive-pack"]:
                raise Exception("Invalid command")
                
            m = re.match(r"'/([a-z0-9-]+).git'", argv[1])

            # malformed or non shell safe path
            if not m:
                raise Exception("Invalid path")

            # not in ACL for SSH fingerprint
            if m.group(1) not in self.user.repos:
                raise Exception("Invalid path")

            # forward SSH connection
            # self.process = reactor.spawnProcess( ... )

        def getPty(self, term, windowSize, attrs):
            raise Exception("no ptys")

        def openShell(self, trans):
            raise Exception("no shells")

        def eofReceived(self):
            pass

        def closed(self):
            pass

    def __init__(self):
        components.registerAdapter(self.GitSession, self.GitUser, session.ISession)

        p = portal.Portal(self.GitRealm())
        p.registerChecker(self.RepoACL())
        self.ExampleFactory.portal = p

    def run(self):
        port = int(os.environ.get('PORT', 5022))
        reactor.listenTCP(5022, self.ExampleFactory())
        reactor.run()
