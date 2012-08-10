#!/bin/bash
echo "Heroku receiving push..."

GIT_DIR=$(pwd)
WORK_TREE=$(dirname $GIT_DIR)/app # GIT_WORKING_TREE ?

export HOME=/Users/noah

read oldrev newrev ref
mkdir -p $WORK_TREE
git --work-tree=$WORK_TREE checkout -f $newrev 2>/dev/null
cd /app/vendor/anvil
bin/compile $WORK_TREE
