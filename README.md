# 🗺️ OSRM-VROOM Combined Router Image

This custom Docker image provides a complete Vehicle Routing Problem (VRP) solution by running both **OSRM (Open Source Routing Machine)** and **VROOM (Vehicle Routing Open-source Optimization Module)** behind a single **Nginx Reverse Proxy**.

This setup allows optimization requests via VROOM while relying on OSRM for fast, underlying geographical routing data.

## 🚀 Quick Start

### 1\. Prerequisites

You must have a map file in **OSM PBF format** (e.g., `great-britain-latest.osm.pbf`) to use this image.

### 2\. Prepare the Data Directory

Place your `.osm.pbf` file in a dedicated local directory (e.g., `./data`).

```bash
mkdir -p ./data
# Copy your map file here, e.g., mv ~/Downloads/map.osm.pbf ./data/
```

### 3\. Build the Image

Assuming your `Dockerfile`, `entrypoint.sh`, `nginx.conf`, and `vroom-config.yml` are in the current directory:

```bash
docker build -t osrm-vroom-router:latest .
```

### 4\. Run the Container

You must pass the full path of the PBF file *inside the container* as the `CMD` argument. We mount the local `./data` directory to `/data` inside the container.

```bash
docker run -d \
    --name osrm-vroom \
    -p 8080:8080 \
    -v $(pwd)/data:/data \
    osrm-vroom-router:latest \
    /data/your-map-file.osm.pbf
```

> **Note:** The first run will be slow as it executes `osrm-extract`, `osrm-partition`, and `osrm-customize`. Subsequent runs (if the data persists in `/data`) will skip this step.

-----

## 🛠️ Service Architecture

All external traffic enters the container through the Nginx proxy (Port 80). Nginx routes traffic based on the URL path:

| Service | Container Port | External Endpoint    | Purpose |
| :--- |:---------------|:---------------------| :--- |
| **OSRM** | `5000`         | `/osrm/route/v1/...` | Fast map routing (used by VROOM and clients) |
| **VROOM** | `3000`         | `/vroom/...`         | Solves VRP using OSRM data |
| **Nginx Proxy** | `8080`         | `/`                  | Traffic entry point |

-----

## ⚙️ Configuration Files

### 1\. `entrypoint.sh`

This script manages the lifecycle of the services:

1.  **Preprocessing:** Checks if partition data files exist. If not, it executes `osrm-extract`, `osrm-partition`, and `osrm-customize`. **Exits on any preprocessing failure.**
2.  **OSRM Startup:** Starts `osrm-routed` in the background.
3.  **Health Check:**  Checks OSRM status and verifies that the OSRM process is still running (using `kill -0`). **Exits if OSRM crashes.**
4.  **VROOM Startup:** Starts `npm start` (VROOM-express) in the background.
5.  **Health Check:** Checks VROOM health status. **Exits if VROOM fails to start.**
6.  **Nginx Startup:** Executes `nginx -g "daemon off;"` to keep the container running.

### 2\. `nginx.conf` (Proxy Logic)

```nginx
# ... (simplified)

upstream osrm_backend {
    server 127.0.0.1:5000;
}
upstream vroom_backend {
    server 127.0.0.1:3000;
}

server {
    listen 80;
    
    # Route OSRM requests
    location ~ ^/osrm/(.*)$ {
        proxy_pass http://osrm_backend/$1$is_args$args;
        # ... headers
    }

    # Route VROOM requests
    location ~ ^/vroom/(.*)$ {
        proxy_pass http://vroom_backend/$1$is_args$args;
        # ... headers
    }
}
```

### 3\. `vroom-config.yml`

This file ensures that the VROOM-express instance inside the container correctly points to the OSRM instance running locally on port 5000.

```yaml
routingServers:
  osrm:
    car:
      host: 'localhost'
      port: '5000'
```

-----

## 🧪 Testing Endpoints

Once the container is running and stable:

| Service | Example URL (External)                                   | Test Purpose |
| :--- |:---------------------------------------------------------| :--- |
| **OSRM** | `http://localhost/osrm/route/v1/driving/0.0,0.0;0.1,0.1` | Simple route query (adjust coordinates) |
| **VROOM** | `http://localhost/vroom`                                 | Post a JSON VRP request payload |
| **Healthcheck** | `http://localhost/healthcheck`                           | Checks Nginx accessibility |

-----

## 🛑 Troubleshooting

| Issue | Possible Cause | Solution |
| :--- | :--- | :--- |
| **"Critical Error: OSRM is unavailable..."** | OSRM process died due to data error. | Check container logs (`docker logs osrm-vroom`). Ensure the PBF file is valid and the profile (`car.lua`) is correct for your OSRM version. |
| **"VROOM is unavailable..."** | VROOM crashed, usually due to upstream OSRM not being ready quickly enough, or configuration error. | Verify `vroom-config.yml` points to `127.0.0.1:5000`. |
| **`proxy_pass` 404/502 errors** | Nginx is running, but backend service is unreachable. | The service died *after* the `entrypoint.sh` health check passed. Check `docker logs` for OSRM/VROOM runtime errors. |


-----

## 📜 Licensing and Attribution

This Docker image combines components released under different open-source licenses. The user is responsible for complying with all applicable license terms.

- [OSRM License](https://github.com/Project-OSRM/osrm-backend?tab=BSD-2-Clause-1-ov-file#readme)
- [VROOM License](https://github.com/VROOM-Project/vroom-express?tab=BSD-2-Clause-1-ov-file#readme)
