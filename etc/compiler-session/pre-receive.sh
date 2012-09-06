#!/bin/bash
export PATH=/usr/local/bin/:$PATH # prefer homebrew ruby 1.9.X

echo "Heroku receiving push..."

HTTP_CODE=$(curl -K ../curl_get_release.conf)

read oldrev newrev ref

../slug-compiler/bin/slugc -t --range=$oldrev..$newrev --meta=../push_metadata.json --deploy-hooks --repo-dir=$(pwd)