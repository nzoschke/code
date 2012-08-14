#!/bin/bash
set -e
#exec 1>&3 2>&3

function log() {
  echo app=codon file=init.sh pwd=$(pwd) "$@" 1>&3
}

if [ ! -f repo/HEAD ]; then
  # TODO: replace with bin/s3 call!?
  log fn=get_repo
  HTTP_CODE=$(curl -K curl_get_repo.conf)
  log fn=get_repo code=$HTTP_CODE

  (
    git bundle verify bundle \
    && git clone --bare bundle repo \
    || git init --bare repo 
  ) 1>&3 2>&3

  mkdir -p            repo/hooks
  cp pre-receive.sh   repo/hooks/pre-receive
  cp post-receive.sh  repo/hooks/post-receive
fi
