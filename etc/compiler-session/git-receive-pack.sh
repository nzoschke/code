#!/bin/bash
set -e

function _exit() {
  tmp=$(pwd)
  [[ "$tmp" == */tmp* ]] && rm -rf $tmp # only remove tmp-ish dirs
}
trap _exit EXIT

function log() {
  echo app=codon file=git-receive-pack.sh "$@" >&3 # FD 3 connected to parent STDERR
}

export GIT_DIR=$(pwd)/repo.git

echo -ne "Heroku preparing repository..." >&2

log fn=get_repo
HTTP_CODE=$(curl -K curl_get_repo.conf)
log fn=get_repo code=$HTTP_CODE

(
  git bundle verify file.bundle \
    && git clone file.bundle $GIT_DIR \
    || git init --bare $GIT_DIR
) 1>&3 2>&3

echo " done" >&2

mkdir               $GIT_DIR/hooks
cp pre-receive.sh   $GIT_DIR/hooks/pre-receive
cp post-receive.sh  $GIT_DIR/hooks/post-receive
git-receive-pack    $GIT_DIR
