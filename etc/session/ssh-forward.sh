#!/bin/bash
# set -x

function _exit() {
  tmp=$(pwd)
  [[ "$tmp" == */tmp* ]] && rm -rf $tmp # only remove tmp-ish dirs
}
trap _exit EXIT

function log() {
  # fd 3 connected to parent STDERR
  echo app=codon file=ssh-forward.sh "$@" >&3
}

log fn=setup
HTTP_CODE=$(curl -K curl_setup.conf)
log fn=setup code=$HTTP_CODE

[[ $HTTP_CODE == 200 ]] || { echo "invalid path"; exit 1; }

log fn=forward
csplit -sf c compiler.conf "/^##/" "{1}"  # Compiler API returns host, port and SSH key config
cat c00 >> ssh.conf                       # append hostname/port config
cat c01 >> id_rsa                         # save user private key
cat c02 >> known_hosts                    # save host public key
chmod 600 id_rsa
ssh -F ssh.conf -C "$@" | tee ssh.log
log fn=forward code=${PIPESTATUS[0]}

log fn=record
HTTP_CODE=$(curl -K curl_record.conf)
log fn=record code=$HTTP_CODE
