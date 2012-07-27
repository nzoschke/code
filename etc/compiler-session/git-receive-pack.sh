#!/bin/bash
set -e

export GIT_DIR=$(pwd)/repo.git

if [ ! -d "$GIT_DIR" ]; then
  echo -ne "Heroku preparing repository..." >&2
  source init.sh
  echo " done" >&2
fi

git-receive-pack $GIT_DIR
