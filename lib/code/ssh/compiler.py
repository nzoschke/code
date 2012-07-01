from Crypto.PublicKey import RSA
from twisted.conch.ssh.keys import Key

class Proxy(SSH):
  def __init__(self):
    url = urlparse(os.environ.get("COMPILER_API_URL"))
    self.api_key = url.password
    self.api_url = "%s://%s:%s%s" % (url.scheme, url.hostname, url.port, url.path)
    self.key     = os.environ.get("SSH_PRIVATE_KEY")

  def requestUser(self, key):
    # GET Compiler API
      fingerprint = keys.Key.fromString(data=credentials.blob).fingerprint()
      f = urllib.quote(fingerprint)
      auth = base64.encodestring("%s:%s" % os.environ['GITPROXY_API_PASSWORD']).rstrip()

      agent = Agent(reactor)
      d = agent.request(
        "GET",
        "%s/compiler" % self.api_url
        Headers({'Authorization': ["Basic %s" % CORE_AUTH]}),
        None)
      d.addCallback(self._cbRequestAvatarId, fingerprint)    
      return d

    pass

  def execCommand(self, proto, cmd):
    # POST path to Compiler/:repository API
    pass

class Compiler(SSH):
  def __init__(self):
    self.key        = RSA.generate(2048) # generate one-time-use key
    self.public_key = Key(key).public().toString("OPENSSH")

  def onStart(self):
    # PUT public_key, hostname and port to session callback_url
    pass

  def requestUser(self, key, reactor):
    # compare keys
    return key.fingerprint()

  def execCommand(self, proto, cmd):
    pass
