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
    echo "OSRM unavailable (waiting 5s)..."
    sleep 5
done
echo "✅ OSRM is ready."


echo "Starting VROOM-express (using OSRM at $OSRM_HOST)"
cd /vroom-express && npm start &
VROOM_PID=$!
echo "Waiting for VROOM-express to become ready on $VROOM_HOST..."
start_time=$(date +%s)
until curl --output /dev/null --silent --fail "$VROOM_HOST/health"; do
    current_time=$(date +%s)
    if [ $((current_time - start_time)) -ge $TIMEOUT ]; then
        echo "Critical Error: Timeout reached. VROOM failed to start correctly."
        kill $OSRM_PID 2>/dev/null
        kill $VROOM_PID 2>/dev/null
        exit 1
    fi
    echo "VROOM unavailable (waiting 5s)..."
    sleep 5
done
echo "✅ VROOM is ready."


echo "Starting Nginx as a reverse proxy in the foreground."
exec nginx -g "daemon off;"
