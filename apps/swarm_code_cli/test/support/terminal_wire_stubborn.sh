#!/bin/sh
# Never reads the protocol fd and ignores SIGTERM (the ignored disposition
# survives exec): only SIGKILL ends it. Verifies the owner reaps its helper.
trap '' TERM
exec /bin/sleep 30
