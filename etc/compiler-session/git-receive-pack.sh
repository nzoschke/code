#!/bin/bash
set -e

echo -ne "Heroku preparing repository..." >&2
source init.sh
echo " done" >&2

git-receive-pack $GIT_DIR
