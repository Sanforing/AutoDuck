#!/bin/zsh
# Ad-hoc signed builds change identity on every rebuild, which can leave a stale
# microphone-permission record. Run this if Mr. AutoDuck stops getting mic access.
BUNDLE_ID="${BUNDLE_ID:-com.mrautoduck.app}"
tccutil reset Microphone "$BUNDLE_ID" && echo "Reset microphone permission for $BUNDLE_ID"
