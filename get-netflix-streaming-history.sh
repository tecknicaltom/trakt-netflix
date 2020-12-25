#!/bin/bash -x

if [[ $# -ne 1 ]]
then
	echo Usage: $0 'Cookie: header'
	exit 1
fi

API_VERSION=$(curl -s 'https://www.netflix.com/settings/viewed/' -H "$1" | grep -oP '(?<="X-Netflix.uiVersion":")[^"]*(?=")')
PGSIZE=20 # they capped page size to 20 :-(

pg=0
while :
do
	JSON=$(curl -s 'https://www.netflix.com/api/shakti/'$API_VERSION'/viewingactivity?pg='$pg'&pgSize='$PGSIZE -H "$1")
	SIZE=$(echo "$JSON" | jq '.viewedItems | length')
	echo "$JSON" | jq '.viewedItems[]'
	echo $pg $SIZE >&2
	if [[ $SIZE -lt $PGSIZE ]]
	then
		break
	fi
	pg=$(( $pg + 1 ))
	sleep 2
done | jq --sort-keys --slurp . | tee netflix-streaming-history-$(date -Isecond).json
