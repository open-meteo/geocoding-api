#!/bin/bash -e

echo "Running before-install.sh"

/usr/bin/mkdir -p /var/lib/geocoding-api/
/usr/sbin/useradd --user-group geocoding-api || echo "User exists already"
