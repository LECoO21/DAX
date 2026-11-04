#!/bin/bash
# @raycast.schemaVersion 1
# @raycast.title DAX 翻译
# @raycast.mode silent
# @raycast.packageName DAX
# @raycast.argument1 {"type": "text", "placeholder": "需要翻译的文字"}
set -euo pipefail
url="$(/usr/bin/python3 -c 'import sys, urllib.parse; print("dax://translate?" + urllib.parse.urlencode({"text": sys.argv[1]}))' "$1")"
/usr/bin/open "$url"
