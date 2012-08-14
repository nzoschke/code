#!/bin/bash
set -e

if [ ! -f repo/HEAD ]; then
  echo -ne "Heroku preparing repository..." >&2
  source init.sh
  echo " done" >&2
fi

git-receive-pack repo
