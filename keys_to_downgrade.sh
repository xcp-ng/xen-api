#!/usr/bin/env bash

old="$1"
new="$2"

echo "Looking for new fields added after $old and before $new"

json="_build/default/ocaml/doc/jekyll/_data/xenapi.json"
return=$(git rev-parse HEAD)

get_fields () {
    git checkout -q $1
    dune build $json
    cat $json | jq '.[].fields.[].name' > "/tmp/$1"
    git checkout -q -
}

get_fields $new
get_fields $old

diff /tmp/{"$old","$new"}

