#!/bin/bash
echo "Heroku receiving push..."

read oldrev newrev ref

mkdir -p ../app
git --work-tree=../app checkout -f $newrev 2>/dev/null

cd ../anvil
bin/compile ../app
bin/stow    ../app