#!/bin/bash

export JEKYLL_VERSION=3.8

docker run -it --rm -p 4000:4000 \
  --volume="$PWD:/srv/jekyll" \
  --volume="$PWD/vendor/bundle:/usr/local/bundle" \
  jekyll/jekyll:$JEKYLL_VERSION \
  $@
