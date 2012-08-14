#!/bin/bash

echo "DONE! Bundle and stow $(pwd)..."
git bundle create bundle --all
HTTP_CODE=$(curl -K ../curl_put_repo.conf)
