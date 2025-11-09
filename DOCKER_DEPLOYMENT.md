# IPTV Panel: Docker Deployment Guide

This guide provides step-by-step instructions for deploying the IPTV Panel using Docker and Docker Compose. This method is recommended for its portability, security, and ease of management.

## Prerequisites

1.  **Docker:** You must have Docker installed on your server. [Install Docker](https://docs.docker.com/engine/install/)
2.  **Docker Compose:** You must have Docker Compose installed. [Install Docker Compose](https://docs.docker.com/compose/install/)
3.  **Domain Name:** You need a domain name (e.g., `panel.yourdomain.com`) pointing to your server's public IP address. This is required for generating the SSL certificate.

---

## Step 1: Configure Your Environment

All configuration is handled through a single `.env` file.

1.  **Copy the Example File:**
    In the root of the project, copy the example environment file:
    ```bash
    cp .env.docker-example .env
    ```

2.  **Edit the `.env` File:**
    Open the newly created `.env` file and customize the following variables. **You must change the default passwords and secrets.**

    ```ini
    # --- Domain & SSL ---
    # Change to your actual domain name.
    PANEL_DOMAIN=panel.yourdomain.com
    # Change to your actual email for SSL notifications.
    CERTBOT_EMAIL=youremail@yourdomain.com

    # --- Database Settings ---
    # It's highly recommended to change the default DB password.
    DB_PASS=YourStrongDBPassword

    # --- Application Settings ---
    # Replace with a new random string (e.g., run `openssl rand -hex 32`)
    SECRET_KEY=YourFlaskSecretKey
    # Set the desired initial password for the 'admin' user.
    ADMIN_PASSWORD=YourStrongAdminPassword
    # Replace with a new random string for the API.
    ADMIN_API_TOKEN=YourAPIToken
    ```

---

## Step 2: Build and Start the Application

Once your `.env` file is configured, you can start the entire application stack with a single command.

```bash
docker-compose up --build -d
```

-   `--build`: This flag tells Docker Compose to build the `panel` image from the `Dockerfile` the first time you run it.
-   `-d`: This runs the containers in detached mode (in the background).

The first launch will take a few minutes as it downloads the necessary Docker images and builds the application container. The `panel` container will automatically wait for the database to be ready and then run the necessary database migrations.

---

## Step 3: Generate the SSL Certificate

For security, the panel is configured to run over HTTPS. You need to run the `certbot` service to generate a free Let's Encrypt SSL certificate.

1.  **Run Certbot:**
    Execute the following command to start the certificate generation process:
    ```bash
    docker-compose run --rm certbot
    ```
    Certbot will communicate with Let's Encrypt and use the Nginx server to verify your domain. The generated certificates will be stored in a Docker volume, so they will persist even if the containers are removed.

2.  **Restart Nginx:**
    After the certificate is successfully generated, restart the Nginx container to make it load the new SSL certificate:
    ```bash
    docker-compose restart nginx
    ```

Your panel should now be live and accessible at `https://<your_panel_domain>`.

---

## Managing Your Dockerized Panel

### Viewing Logs

To view the logs for all running services in real-time:
```bash
docker-compose logs -f
```

To view the logs for a specific service (e.g., the `panel`):
```bash
docker-compose logs -f panel
```

### Stopping the Application

To stop all the running containers:
```bash
docker-compose down
```
This command stops and removes the containers but **does not** delete your database data or SSL certificates, as they are stored in Docker volumes.

### Restarting a Service

To restart a single service (e.g., after a configuration change):
```bash
docker-compose restart <service_name>
# Example:
docker-compose restart panel
```

### SSL Certificate Renewal

Let's Encrypt certificates are valid for 90 days. You should set up a cron job on your host machine to automatically renew them.

1.  Create a script named `renew_ssl.sh`:
    ```bash
    #!/bin/bash
    # Navigate to your project directory
    cd /path/to/your/IptvPannel
    # Run the certbot renewal command
    docker-compose run --rm certbot renew
    # Reload nginx to pick up the new certs
    docker-compose restart nginx
    ```
    Make the script executable: `chmod +x renew_ssl.sh`.

2.  Add a cron job to run this script periodically (e.g., once a week):
    ```bash
    # Edit crontab
    crontab -e

    # Add this line to run the script every Sunday at 3:30 AM
    30 3 * * 0 /path/to/your/renew_ssl.sh > /var/log/cron_ssl_renew.log 2>&1
    ```
