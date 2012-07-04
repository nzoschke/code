#!/usr/bin/env python

import os
import shlex
import sys

from twisted.cred import portal, checkers
from twisted.cred.error import UnauthorizedLogin
from twisted.conch import error, avatar
from twisted.conch.checkers import SSHPublicKeyDatabase
from twisted.conch.ssh import factory, userauth, connection, keys, session
from twisted.internet import reactor, protocol, defer
from twisted.python import components, failure, log
from zope.interface import implements

log.startLogging(sys.stderr)

class Server(object):
    class SSHFactory(factory.SSHFactory):
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

    class KeyChecker(SSHPublicKeyDatabase):
        def requestAvatarId(self, credentials):
            return failure.Failure(UnauthorizedLogin("Access disabled"))

    class SSHRealm:
        implements(portal.IRealm)

        def requestAvatar(self, avatarId, mind, *interfaces):
            return interfaces[0], Server.User(avatarId), lambda: None

    class User(avatar.ConchUser):
        def __init__(self, username):
            avatar.ConchUser.__init__(self)
            self.username = username
            self.channelLookup.update({ "session": session.SSHSession })

    class SSHSession:    
        def __init__(self, user):
            self.user = user

        def execCommand(self, proto, cmd):
            raise Exception("no execs")

        def getPty(self, term, windowSize, attrs):
            raise Exception("no ptys")

        def openShell(self, trans):
            raise Exception("no shells")

        def eofReceived(self):
            pass

        def closed(self):
            pass

    def __init__(self):
        # metaprogramming plumbing
        self.SSHFactory.startFactory        = self.startFactory
        self.SSHFactory.onStart             = self.onStart
        self.KeyChecker.requestAvatarId     = self.requestAvatarId
        self.KeyChecker.requestUsername     = self.requestUsername
        self.SSHSession.closed              = self.closed
        self.SSHSession.eofReceived         = self.eofReceived
        self.SSHSession.execCommand         = self.execCommand
        self.SSHSession.onClose             = self.onClose
        self.SSHSession.spawnProcess        = self.spawnProcess

    @staticmethod
    def startFactory(self):
        factory.SSHFactory.startFactory(self)
        self.onStart()

    @staticmethod
    def requestAvatarId(self, credentials):
        key = keys.Key.fromString(data=credentials.blob)

        if not credentials.signature:
          return failure.Failure(error.ValidPublicKey())
        if not keys.Key.verify(key, credentials.signature, credentials.sigData):
          return failure.Failure(error.ConchError("Incorrect signature"))

        return self.requestUsername(key)

    def onStart(self):
        pass

    def requestUsername(self, key):
        return failure.Failure(UnauthorizedLogin("Access disabled"))

    @staticmethod
    def execCommand(self, proto, cmd):
        lexer = shlex.shlex(cmd)
        lexer.whitespace_split = True
        argv = [s for s in lexer]

        return self.spawnProcess(proto, self.user.username, argv)

    def spawnProcess(self, proto, username, argv):
        raise Exception("Commands disabled")

    @staticmethod
    def eofReceived(self):
        return self.onClose()

    @staticmethod
    def closed(self):
        return self.onClose()

    def onClose(self):
        pass

    def run(self, port=5022):
        components.registerAdapter(self.SSHSession, self.User, session.ISession)

        p = portal.Portal(self.SSHRealm())
        p.registerChecker(self.KeyChecker())
        self.SSHFactory.portal = p

        reactor.listenTCP(int(port), self.SSHFactory())
        reactor.run()
