#!/bin/bash
set -x

function log() {
  echo app=codon file=ssh-forward.sh "$@" >&2
}

log fn=setup
ssh-keygen -f id_rsa -N "" >&2
HTTP_CODE=$(curl -K curl_setup.conf)
rm id_rsa # clean private key as soon as possible
log fn=setup code=$HTTP_CODE

[[ $HTTP_CODE == 200 ]] || exit 1

log fn=forward
ssh -F ssh.conf | tee ssh.log
log fn=forward code=${PIPESTATUS[0]}

log fn=record
HTTP_CODE=$(curl -K curl_record.conf)
log fn=record code=$HTTP_CODE
