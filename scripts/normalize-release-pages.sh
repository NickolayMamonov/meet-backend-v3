#!/usr/bin/env bash
set -euo pipefail

jq -cse '
  if length == 1 and
     (.[0] | type == "array") and
     (.[0] | all(.[]; type == "array")) and
     (.[0] | all(.[][]; type == "object"))
  then [.[0][][]]
  else error("release API response must be one array of pages containing release objects")
  end
'
