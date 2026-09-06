#!/bin/sh
# Deliberately emits no records; owner tests inject bounded native responses.
exec /bin/cat <&3 > /dev/null
