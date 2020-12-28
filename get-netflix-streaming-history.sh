#!/bin/bash -x

if [[ $# -ne 1 ]]
then
	echo Usage: $0 'Cookie: header'
	exit 1
fi

API_VERSION=$(curl -s 'https://www.netflix.com/settings/viewed/' -H "$1" | grep -oP '(?<="X-Netflix.uiVersion":")[^"]*(?=")')
PGSIZE=20 # they capped page size to 20 :-(
SKIP_PROFILE_GUIDS="VOHTRNK3"

PROFILE_GUIDS=$(curl -s 'https://www.netflix.com/YourAccount' -H "$1" | grep -oP '"rawFirstName":"[^"]*","guid":"[^"]*"' | sort -u)

for profile_guid in $PROFILE_GUIDS
do
	GUID=$(echo "{$profile_guid}" | sed 's#\\x20# #g' | jq -r .guid)
	if $(echo $GUID | grep -q $SKIP_PROFILE_GUIDS)
	then
		next
	fi

	pg=0
	while :
	do
		JSON=$(curl -s 'https://www.netflix.com/api/shakti/'$API_VERSION'/viewingactivity?pg='$pg'&pgSize='$PGSIZE'&guid='$GUID -H "$1")
		SIZE=$(echo "$JSON" | jq '.viewedItems | length')
		echo "$JSON" | jq '.viewedItems[]'
		echo $pg $SIZE >&2
		if [[ $SIZE -lt $PGSIZE ]]
		then
			break
		fi
		pg=$(( $pg + 1 ))
		sleep 2
	done
done | jq --sort-keys --slurp . | tee netflix-streaming-history-$(date -Isecond).json
