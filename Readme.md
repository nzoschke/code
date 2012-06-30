# Codon

## bin/http_proxy

## bin/http_compiler

## bin/ssh_proxy

SSH Proxy is an server that receives a `git push` SSH connection, composed of a SSH fingerprint and command. The allowed commands are either:

    git-receive-pack <repository>.git
    git-upload-pack  <repository>.git

The SSH fingerprint and repository name are presented to a Director service, which returns a one-time-use SSH key, hostname and port of a compiler container, which Proxy forwards the connection to.

## bin/ssh_compiler

SSH Compiler is an SSH server inside a container for untrusted code compilation in git hooks. The only environment it has is:

  * A one-time-use callback URL to send hostname and port to the Director
  * A one-time-use private SSH key
  * Pre-signed URLs for GET/PUT of a git repository bundle
  * Pre-signed URLs for GET/PUT of a build cache tgz
  * Pre-signed URL for PUT of a build image
  * A one-time-use callback URL to send build status to the Director

Upon receiving a connection, the compiler will download and extract the git bundle at REPO_GET_URL, then execute the `git-receive-pack` or `git-upload-pack`.

If the command is `git-receive-pack`, the compiler will install a `pre_receive` hook to download and extract the build cache at CACHE_GET_URL, run a buildpack, then store 

## API::Director
  
    curl -H "Accept: application/json" \
      -u :$SSH_FINGERPRINT \
      -X POST https://code.heroku.com/compiler/:repository

    HTTP/1.1 200 OK
    {
      hostname:   "10.5.1.122",
      port:       "19241",
      public_key: "ssh-rsa AAAA..."
    }

  The compiler API blocks while setting up a new container. This is created with the `heroku run` API:

    curl -H "Accept: application/json" \
      -u :HEROKU_RUN_API_KEY \
      -d "attach=false" \
      -d "command=bin/compiler" \
      -d "ps_env[callback_url]=..." \
      -d "ps_env[build_callback_url]=..." \
      -d "ps_env[build_put_url]=..." \
      -d "ps_env[cache_get_url]=..." \
      -d "ps_env[cache_put_url]=..." \
      -d "ps_env[private_key]=..." \
      -d "ps_env[route_url]=..." \
      -d "ps_env[repo_get_url]=..." \
      -d "ps_env[repo_put_url]=..." \
      -d "ps_env[request_id]=..." \
      -X POST https://api.heroku.com/apps/cedar-compiler/ps

The container fetches starts an SSH server