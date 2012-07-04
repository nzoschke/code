#!/bin/bash
set -x

function _exit() {
  tmp=$(pwd)
  [[ "$tmp" == */tmp* ]] && rm -rf $tmp   # only remove tmp-ish dirs
}
trap _exit EXIT

function log() {
  echo app=codon file=ssh-forward.sh "$@" >&2
}

log fn=setup
ssh-keygen -f id_rsa -N "" >&2            # TODO: move key management to server for security?
HTTP_CODE=$(curl -K curl_setup.conf)
log fn=setup code=$HTTP_CODE

[[ $HTTP_CODE == 200 ]] || { echo "invalid path"; exit 1; }

log fn=forward
ssh localhost -F ssh.conf -i id_rsa -p 6022 -C "$@" | tee ssh.log
#ssh -F ssh.conf | tee ssh.log
log fn=forward code=${PIPESTATUS[0]}

log fn=record
HTTP_CODE=$(curl -K curl_record.conf)
log fn=record code=$HTTP_CODE
