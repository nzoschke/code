#!/bin/bash
set -e

function log() {
  echo app=codon file=init.sh pwd=$(pwd) "$@" >&3
}

export GIT_DIR=$(pwd)/repo.git

if [ ! -d "$GIT_DIR" ]; then
  # TODO: replace with bin/s3 call!
  log fn=get_repo
  HTTP_CODE=$(curl -K curl_get_repo.conf)
  log fn=get_repo code=$HTTP_CODE

  (
    git bundle verify file.bundle \
      && git clone --bare file.bundle $GIT_DIR \
      || git init  --bare $GIT_DIR
  ) 1>&3 2>&3

  mkdir -p            $GIT_DIR/hooks
  cp pre-receive.sh   $GIT_DIR/hooks/pre-receive
  cp post-receive.sh  $GIT_DIR/hooks/post-receive
fi

