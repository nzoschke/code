#!/bin/bash
echo "Heroku receiving push..."

GIT_DIR=$(pwd)
WORK_TREE=$(dirname $GIT_DIR)/app # GIT_WORKING_TREE ?

export HOME=/Users/noah

read oldrev newrev ref
if [ "$ref" = "refs/heads/anvil" ]; then
  mkdir -p $WORK_TREE
  git --work-tree=$WORK_TREE checkout -f $newrev 2>/dev/null
  SLUG_URL=$(heroku build -p)
  echo "Heroku releasing $SLUG_URL"
  exit 0
fi