#!/bin/sh
#
# Update Pihole's custom.list based on the "hostname" property of a container.
#
# Environment variables
# - OVERRIDE_IP sets the IP of the container in Pihole's DNS records. Defaults to container IP in Docker network.
# - DOMAIN_FILTER only triggers the updates on a match. If empty, it'll always update the records file.
# - PIHOLE_CUSTOM_LIST_FILE /etc/hosts compatible DNS records file in format "IP hostname".
# - PIHOLE_CONTAINER_NAME because we need to reload Pihole's internal resolver when making changes
#
# How to use: Run a container based on the official "docker:cli" image and set this
# file as the "command/run" parameter. Make sure to mount Pihole's configuration directory as well.
# Set OVERRIDE_IP to your external IP, otherwise the IPs will be set to Docker's internal IPs.

host_format="{{.Config.Hostname}} {{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}"

if [ -z "$PIHOLE_CUSTOM_LIST_FILE" ]; then
    export PIHOLE_CUSTOM_LIST_FILE="/etc/pihole/custom.list"
fi

if [ -z "$PIHOLE_CONTAINER_NAME" ]; then
    export PIHOLE_CONTAINER_NAME="pihole"
fi

# Because Pihole doesn't watch the custom lists file for being updated outside the admin GUI,
# we need to reload its DNS lists manually whenever we make changes to the custom.list file
reload_pihole() {
    docker exec $PIHOLE_CONTAINER_NAME pihole restartdns reload
}

update_records_file() {
    hostname="$1"
    status="$2"
    ip="$3"

    # Always remove any existing entry with the hostname
    sed -i "/\b$hostname\b/d" $PIHOLE_CUSTOM_LIST_FILE

    if [[ "${status}" == "stop" ]]; then
        echo "Removed entry for $hostname from $PIHOLE_CUSTOM_LIST_FILE"
	return 0
    fi

    if [ -n "$DOMAIN_FILTER" ] && ! echo "$hostname" | grep -qE "$DOMAIN_FILTER"; then
	echo "Hostname '$hostname' doesn't match DOMAIN_FILTER, not adding."
	return 0
    fi

    if [ -n "$OVERRIDE_IP" ]; then
	ip=$OVERRIDE_IP
    fi

    echo "$ip $hostname" >> $PIHOLE_CUSTOM_LIST_FILE
    echo "Added entry for $ip $hostname to $PIHOLE_CUSTOM_LIST_FILE"

    return 0
}

# When starting up, add all container hostnames to Pihole's custom.list file
# and reload it for the changes to take effect immediately
docker inspect -f "$host_format" $(docker ps -q) | while read hostname ip; do
    if [ -n "$ip" ] && [ -n "$hostname" ]; then
        update_records_file "$hostname" "update" "$ip"
    fi
done

echo "Added initial entries to $PIHOLE_CUSTOM_LIST_FILE, reloading $PIHOLE_CONTAINER_NAME"
reload_pihole

# Watch for containers stopping and starting, modifying records file accordingly
# IP is the last parameter deliberately because it becomes empty on "stop" event
docker events \
    --filter 'type=container' \
    --filter 'event=start' \
    --filter 'event=stop' \
    --format '{{.Status}} {{.ID}}' | while IFS= read -r event; do

    set -- $event
    status="$1"
    container_id="$2"

    container=$(docker inspect -f "$host_format" $container_id)

    set -- $container
    hostname="$1"
    ip="$2"

    update_records_file "$hostname" "$status" "$ip"
    reload_pihole
done
