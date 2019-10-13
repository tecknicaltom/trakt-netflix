#!/bin/bash

jq -r '.[] | select(.seriesTitle) | select(.seriesTitle | contains("'"$1"'")) | (.date/1000 | strftime("%b %e, %Y %R +0000")) + " / " + .seriesTitle + " / " + .title' "$(ls netflix-streaming-history-* | tail -n1)" | tac
