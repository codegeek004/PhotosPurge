#!/bin/bash

# exit on errors
set -e

PROJECT_DIR="/home/azureuser/codemos-hackathon/PhotoPurge"
VENV_DIR="${PROJECT_DIR}/venv"
USER="azureuser"
GROUP="www-data"
DOMAIN="codemos-services.co.in"
EMAIL="admin@codemos-services.co.in"


sudo apt update -y
sudo apt upgrade -y
sudo apt install -y python3.11 python3.11-venv python3.11-dev nginx certbot python3-certbot-nginx

python3.11 -m venv "${VENV_DIR}"
source "${VENV_DIR}/bin/activate"
pip install --upgrade pip
pip install -r "${PROJECT_DIR}/requirements.txt"
pip install gunicorn celery

cd "${PROJECT_DIR}"
python manage.py collectstatic --noinput
python manage.py migrate --noinput

sudo mkdir -p /var/log/gunicorn /var/log/celery /var/run/celery
sudo chown -R "${USER}:${GROUP}" /var/log/gunicorn /var/log/celery /var/run/celery
sudo chmod -R 775 /var/log/gunicorn /var/log/celery /var/run/celery

NGINX_CONF="/etc/nginx/sites-available/photopurge.conf"

sudo bash -c "cat > ${NGINX_CONF} << 'EOF'
server {
    server_name codemos-services.co.in www.codemos-services.co.in;

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location /static/ {
        alias /home/azureuser/codemos-hackathon/PhotoPurge/staticfiles/;
    }

    # Security headers
    add_header X-Content-Type-Options nosniff;
    add_header X-Frame-Options DENY;
    add_header X-XSS-Protection \"1; mode=block\";

    listen 80;
}
EOF"

sudo ln -sf "${NGINX_CONF}" /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t
sudo systemctl reload nginx

sudo certbot --nginx \
    -d "${DOMAIN}" -d "www.${DOMAIN}" \
    --non-interactive --agree-tos -m "${EMAIL}" --redirect

GUNICORN_SERVICE="/etc/systemd/system/gunicorn-photopurge.service"

sudo bash -c "cat > ${GUNICORN_SERVICE} << 'EOF'
[Unit]
Description=Gunicorn daemon for PhotoPurge
After=network.target

[Service]
User=azureuser
Group=www-data
WorkingDirectory=/home/azureuser/codemos-hackathon/PhotoPurge
Environment=\"PATH=/home/azureuser/codemos-hackathon/PhotoPurge/venv/bin\"
ExecStart=/home/azureuser/codemos-hackathon/PhotoPurge/venv/bin/gunicorn \
  --workers 2 \
  --bind 127.0.0.1:8000 \
  codegeeks.wsgi:application \
  --access-logfile /var/log/gunicorn/access.log \
  --error-logfile /var/log/gunicorn/error.log

Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF"

CELERY_SERVICE="/etc/systemd/system/celery-photopurge.service"

sudo bash -c "cat > ${CELERY_SERVICE} << 'EOF'
[Unit]
Description=Celery daemon for PhotoPurge
After=network.target

[Service]
Type=forking
User=azureuser
Group=www-data
WorkingDirectory=/home/azureuser/codemos-hackathon/PhotoPurge
Environment=\"PATH=/home/azureuser/codemos-hackathon/PhotoPurge/venv/bin\"
ExecStart=/home/azureuser/codemos-hackathon/PhotoPurge/venv/bin/celery \
  -A codegeeks worker \
  --loglevel=info \
  --logfile=/var/log/celery/worker.log \
  --pidfile=/var/run/celery/worker.pid \
  --detach
ExecStop=/home/azureuser/codemos-hackathon/PhotoPurge/venv/bin/celery -A codegeeks control shutdown
PIDFile=/var/run/celery/worker.pid
StandardOutput=append:/var/log/celery/access.log
StandardError=append:/var/log/celery/error.log
Restart=always

[Install]
WantedBy=multi-user.target
EOF"

sudo systemctl daemon-reload
sudo systemctl enable gunicorn-photopurge.service
sudo systemctl enable celery-photopurge.service

sudo chown -R "${USER}:${GROUP}" "${PROJECT_DIR}"
sudo chmod -R 755 "${PROJECT_DIR}"
sudo chmod 755 /home/azureuser/codemos-hackathon/PhotoPurge/staticfiles

sudo systemctl restart nginx
sudo systemctl restart gunicorn-photopurge
sudo systemctl restart celery-photopurge

echo "Deployment complete!"
