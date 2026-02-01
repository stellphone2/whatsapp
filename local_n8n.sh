#!/bin/bash
# local_n8n.sh — Windows + WSL Docker Desktop installer
set -e

# --- GLOBAL CONFIGURATION ---
PROJECT_DIR="$HOME/evolution-docker"
API_DIR="$PROJECT_DIR/evolution-api"
ABS_PYTHON_DIR="/mnt/c/n8n_python"

SERVER_IP="localhost"
WEB_URL="http://${SERVER_IP}:5678/"

POSTGRES_DB="evolution_db"
POSTGRES_USER="p_user"
POSTGRES_PASSWORD="password"

CACHE_REDIS_ENABLED="true"
CACHE_REDIS_URI="redis://redis:6379/6"

AUTHENTICATION_API_KEY="12345678"
AUTHENTICATION_API_SECRET="password"
LOG_BAILEYS="debug"

echo "Checking Docker availability..."

if ! command -v docker >/dev/null 2>&1; then
  echo "❌ Docker not found. Install Docker Desktop and enable WSL integration."
  exit 1
fi

# --- PREP DIRECTORIES ---
mkdir -p "$PROJECT_DIR"
mkdir -p "$ABS_PYTHON_DIR"

cd "$PROJECT_DIR"

# --- CREATE N8N DOCKERFILE (stable Alpine build) ---
cat > Dockerfile.n8n <<EOF
FROM nikolaik/python-nodejs:python3.11-nodejs20-alpine

USER root

# Update Alpine packages and install dependencies
RUN apk update && \
    apk add --no-cache git build-base su-exec bash tzdata

# Install n8n globally
RUN npm install -g n8n@latest

# Setup Python virtual environment
RUN python3 -m venv /opt/n8n-venv
RUN /opt/n8n-venv/bin/pip install --no-cache-dir requests pandas
RUN chown -R 1000:1000 /opt/n8n-venv

ENV N8N_PYTHON_INTERPRETER=/opt/n8n-venv/bin/python3
ENV PATH="/opt/n8n-venv/bin:/usr/local/bin:/usr/bin:/bin"

USER 1000
EXPOSE 5678
CMD ["n8n"]
EOF

echo "Dockerfile created."

# --- CLONE EVOLUTION API ---
if [ ! -d "$API_DIR" ]; then
  git clone https://github.com/EvolutionAPI/evolution-api.git
fi

echo "Evolution API ready."

# --- ENV CONFIG ---
cat > .env <<ENVEOF
WEBHOOK_URL=${WEB_URL}
N8N_INTERNAL_API_URL=http://localhost:5678/
N8N_REACHABILITY_CHECK_ENABLED=false
N8N_ONBOARDING_SKIP=true
N8N_PERSONALIZATION_ENABLED=false
N8N_EXECUTE_COMMAND_ALLOWLIST=*

DATABASE_PROVIDER=postgresql
POSTGRES_DB=${POSTGRES_DB}
POSTGRES_USER=${POSTGRES_USER}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}

DATABASE_URL=postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@postgres:5432/${POSTGRES_DB}
DATABASE_CONNECTION_URI=postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@postgres:5432/${POSTGRES_DB}

CACHE_REDIS_ENABLED=${CACHE_REDIS_ENABLED}
CACHE_REDIS_URI=${CACHE_REDIS_URI}

AUTHENTICATION_API_KEY=${AUTHENTICATION_API_KEY}
AUTHENTICATION_API_SECRET=${AUTHENTICATION_API_SECRET}
LOG_BAILEYS=${LOG_BAILEYS}
ENVEOF

echo ".env created."

# --- DOCKER COMPOSE ---
cat > docker-compose.yml <<COMPOSEEOF
services:
  postgres:
    image: postgres:15
    container_name: evolution-postgres
    env_file: .env
    environment:
      POSTGRES_DB: \${POSTGRES_DB}
      POSTGRES_USER: \${POSTGRES_USER}
      POSTGRES_PASSWORD: \${POSTGRES_PASSWORD}
    volumes:
      - postgres_data:/var/lib/postgresql/data
    restart: unless-stopped

  redis:
    image: redis:7
    container_name: evolution-redis
    restart: unless-stopped

  evolution-api:
    build: ./evolution-api
    container_name: evolution-api
    env_file: .env
    depends_on:
      - postgres
      - redis
    ports:
      - "8080:8080"
    restart: unless-stopped

  n8n:
    build:
      context: .
      dockerfile: Dockerfile.n8n
    container_name: n8n
    env_file: .env
    environment:
       - N8N_SECURE_COOKIE=false
       - N8N_HOST=0.0.0.0
       - WEBHOOK_URL=${WEB_URL}
       - N8N_INTERNAL_API_URL=http://localhost:5678/
       - N8N_REACHABILITY_CHECK_ENABLED=false
       - N8N_ONBOARDING_SKIP=true
       - N8N_EXECUTE_COMMAND_ALLOWLIST=*
       - NODES_EXCLUDE=[]
    ports:
      - "5678:5678"
    volumes:
      - n8n_data:/home/node/.n8n
      - ${ABS_PYTHON_DIR}:/home/node/python
    restart: unless-stopped

volumes:
  postgres_data:
  n8n_data:
COMPOSEEOF

echo "docker-compose.yml created."

# --- DEPLOY ---
docker rm -f n8n evolution-api evolution-postgres evolution-redis 2>/dev/null || true
docker compose down -v || true
docker compose up -d --build

echo "Containers starting..."

# --- WAIT FOR API ---
until docker logs evolution-api 2>&1 | grep -q "HTTP - ON"; do
  sleep 5
done

docker exec evolution-api npm run db:generate || true
docker exec evolution-api npm run db:deploy

echo "================================================"
echo "✅ Evolution API READY"
echo "🌐 Evolution API: http://localhost:8080"
echo "🌐 n8n: http://localhost:5678"
echo "================================================"
