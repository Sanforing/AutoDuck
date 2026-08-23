#!/bin/zsh
# Ad-hoc signed builds change identity on every rebuild, which can leave a stale
# microphone-permission record. Run this if AutoDuck stops getting mic access.
BUNDLE_ID="${BUNDLE_ID:-com.autoduck.app}"
tccutil reset Microphone "$BUNDLE_ID" && echo "Reset microphone permission for $BUNDLE_ID"
