#!/bin/bash
set -ex

function _exit() {
  tmp=$(pwd)
  #[[ "$tmp" == */tmp* ]] && rm -rf $tmp             # only remove tmp-ish dirs
}
trap _exit EXIT

function log() {
  echo app=codon file=init.sh "$@"
}

export GIT_DIR=$(pwd)/repo.git

# TODO: replace with bin/s3 call!
log fn=get_repo
HTTP_CODE=$(curl -K curl_get_repo.conf)
log fn=get_repo code=$HTTP_CODE

git bundle verify file.bundle \
  && git clone --bare file.bundle $GIT_DIR \
  || git init  --bare $GIT_DIR

mkdir -p            $GIT_DIR/hooks
cp pre-receive.sh   $GIT_DIR/hooks/pre-receive
cp post-receive.sh  $GIT_DIR/hooks/post-receive
