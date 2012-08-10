#!/bin/bash
echo "Heroku receiving push..."

GIT_DIR=$(pwd)
WORK_DIR=$(dirname $GIT_DIR)/app # GIT_WORKING_TREE ?

read oldrev newrev ref

mkdir -p $WORK_DIR
git --work-tree=$WORK_DIR checkout -f $newrev 2>/dev/null
cd /app/vendor/anvil
bin/compile $WORK_DIR
bin/stow    $WORK_DIR