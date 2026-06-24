#!/bin/sh

MAP_PBF_PATH=$1

# Extracts the base map name (e.g., /data/map.osm.pbf -> /data/map)
BASE_MAP_NAME=$(echo "$MAP_PBF_PATH" | sed 's/\.osm\.pbf$//')

OSRM_HOST="http://127.0.0.1:5000"
VROOM_HOST="http://127.0.0.1:3000"
TIMEOUT=60

if [ -z "$MAP_PBF_PATH" ]; then
    echo "Error: The PBF map path (.osm.pbf) was not provided."
    exit 1
fi

# Check if the processed .osrm file already exists. If yes, skip lengthy processing.
if [ ! -f "${BASE_MAP_NAME}.osrm.partition" ]; then
    echo "Processed file ${BASE_MAP_NAME}.osrm not found. Initiating OSRM pre-processing pipeline."

    echo "Starting osrm-extract..."
    osrm-extract -p /opt/car.lua "$MAP_PBF_PATH"

    if [ $? -ne 0 ]; then
        echo "Error: osrm-extract failed."
        exit 1
    fi

    echo "Starting osrm-partition..."
    osrm-partition "$BASE_MAP_NAME.osrm"
    if [ $? -ne 0 ]; then
        echo "Error: osrm-partition failed."
        exit 1
    fi

    echo "Starting osrm-customize..."
    osrm-customize "$BASE_MAP_NAME.osrm"
    if [ $? -ne 0 ]; then
        echo "Error: osrm-customize failed."
        exit 1
    fi

    echo "OSRM pre-processing completed successfully."
else
    echo "Processed OSRM data (${BASE_MAP_NAME}.osrm) already exists. Skipping pre-processing."
fi

OSRM_DATA_PATH="${BASE_MAP_NAME}.osrm"


echo "Starting OSRM-routed with data path: $OSRM_DATA_PATH"
osrm-routed --algorithm mld "$OSRM_DATA_PATH" &
OSRM_PID=$!
echo "Waiting for OSRM to become ready on $OSRM_HOST..."
start_time=$(date +%s)
until curl --output /dev/null --silent --fail "$OSRM_HOST/route/v1/driving/0,0;0,0"; do
    current_time=$(date +%s)
    if [ $((current_time - start_time)) -ge $TIMEOUT ]; then
        echo "Critical Error: Timeout reached. OSRM failed to start correctly."
        kill $OSRM_PID 2>/dev/null
        exit 1
    fi
    echo "OSRM unavailable (waiting 2s)..."
    sleep 2
done
echo "✅ OSRM is ready."


# Start the osrm-radiuses proxy on :5001 → forwards to osrm-routed :5000
# with `radiuses` always overridden (default 50m, configurable via
# OSRM_DEFAULT_RADIUS env var).
echo "Starting osrm-radiuses proxy on port 5001 (→ $OSRM_HOST)..."
node /app/osrm-proxy.js &
PROXY_PID=$!
echo "Waiting for osrm-radiuses proxy to become ready on 127.0.0.1:5001..."
start_time=$(date +%s)
# Don't use --fail: OSRM may return 400 for the test coordinates (0,0
# is in the ocean and will get NoSegment with radiuses).  We only need
# to know the proxy itself is up and forwarding — any HTTP response counts.
until curl --output /dev/null --silent "http://127.0.0.1:5001/route/v1/driving/0,0;0,0" 2>/dev/null; do
    current_time=$(date +%s)
    if [ $((current_time - start_time)) -ge $TIMEOUT ]; then
        echo "Critical Error: Timeout reached. osrm-radiuses proxy failed to start correctly."
        kill $OSRM_PID 2>/dev/null
        kill $PROXY_PID 2>/dev/null
        exit 1
    fi
    echo "osrm-proxy unavailable (waiting 2s)..."
    sleep 2
done
echo "✅ osrm-radiuses proxy is ready (radius=${OSRM_DEFAULT_RADIUS:-50}m, always override)."


echo "Starting VROOM-express (using OSRM proxy at http://127.0.0.1:5001)"
cd /vroom-express && npm start &
VROOM_PID=$!
echo "Waiting for VROOM-express to become ready on $VROOM_HOST..."
start_time=$(date +%s)
until curl --output /dev/null --silent --fail "$VROOM_HOST/health"; do
    current_time=$(date +%s)
    if [ $((current_time - start_time)) -ge $TIMEOUT ]; then
        echo "Critical Error: Timeout reached. VROOM failed to start correctly."
        kill $OSRM_PID 2>/dev/null
        kill $PROXY_PID 2>/dev/null
        kill $VROOM_PID 2>/dev/null
        exit 1
    fi
    echo "VROOM unavailable (waiting 2s)..."
    sleep 2
done
echo "✅ VROOM is ready."


echo "Starting Nginx as a reverse proxy in the foreground."
exec nginx -g "daemon off;"
