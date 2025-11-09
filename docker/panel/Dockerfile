# Dockerfile for the IPTV Panel Application

# --- Base Image ---
# Use a slim, modern Python image
FROM python:3.11-slim-bullseye

# --- Metadata ---
LABEL maintainer="IPTV Panel Autopilot"
LABEL description="Docker image for the IPTV Panel Flask application."

# --- Environment Variables ---
# Prevents Python from writing .pyc files to disc
ENV PYTHONDONTWRITEBYTECODE 1
# Ensures Python output is sent straight to the terminal without buffering
ENV PYTHONUNBUFFERED 1

# --- System Dependencies ---
# Install packages needed for building Python dependencies and for PostgreSQL client
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        libpq-dev \
        postgresql-client \
        curl \
    # Clean up APT cache to reduce image size
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# --- Application Setup ---
# Create a non-root user for security
RUN addgroup --system app && adduser --system --ingroup app app

# Create application directory
WORKDIR /app

# Copy application source code from the 'local_panel' directory
COPY ./local_panel /app

# Install Python dependencies
# Copy requirements first to leverage Docker layer caching
COPY ./local_panel/requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir --upgrade pip \
    && pip install --no-cache-dir -r requirements.txt

# --- Entrypoint & Permissions ---
# Copy the entrypoint script that waits for the DB and runs migrations
COPY ./docker/panel/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Change ownership of the app directory to the non-root user
RUN chown -R app:app /app

# Switch to the non-root user
USER app

# --- Final Command ---
# Expose the port Gunicorn will run on
EXPOSE 5000

# Set the entrypoint
ENTRYPOINT ["/entrypoint.sh"]

# Command to run when the container launches
CMD ["gunicorn", "-w", "4", "-b", "0.0.0.0:5000", "--timeout", "600", "app:app"]
