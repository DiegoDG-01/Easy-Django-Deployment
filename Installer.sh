#!/usr/bin/bash

LOCAL_PATH=$(pwd)

control=0

echo "======= Initializing installation ======="

echo "======= #1: Updating system linux ======="
sudo apt-get -qq update
sudo apt-get -qq upgrade

echo "======= #2: Installing dependencies to use PostgreSQL in Django ======="
sudo apt-get -qq install build-essential libpq-dev python-dev

echo "======= #3: Installing PostgreSQL ======="
sudo apt-get -qq install postgresql postgresql-contrib

echo "======= #4: Installing Web Server (Nginx) ======="
sudo apt-get -qq install nginx

echo "======= #5: Installing Supervisor ======="
sudo apt-get -qq install supervisor

echo "======= #6: Initializing Supervisor ======="
sudo service supervisor enable
sudo service supervisor start

echo "======= #7: Installing Python3 Virtual Environment ======="
sudo apt-get -qq install python3-virtualenv

echo "======= #8: Configure user for Linux and PostgreSQL ======="
read -p 'Usuario para linux (dejar en blanco para usar el default "django"): ' -r USER
read -p 'Usuario para PostgreSQL (dejar en blanco para usar el mismo usuario de linux): ' -r POSTGRES_USER

if [ -z "$USER" ]; then
    USER=django
fi

if [ -z "$POSTGRES_USER" ]; then
    POSTGRES_USER=$USER
fi

echo "======= #9: Configure password for PostgreSQL ======="

while [ $control -eq 0 ];
do
  read -p 'Contraseña para PostgreSQL (no dejar en blanco): ' -r -s POSTGRES_PASSWORD

  if [ -z $POSTGRES_PASSWORD ]; then
    echo ""
    echo "La contraseña no puede estar en blanco!!"
  else
    echo ""
    control=1
  fi
done

echo "======= #10: Configure database name for PostgreSQL ======="
read -p 'Nombre de la base de datos(Dejar en blanco para usar el default "django_production"): ' -r DB_NAME

if [ -z "$DB_NAME" ]; then
    DB_NAME=django_production
fi

echo "======= #11: Configure PostgreSQL ======="
sudo su - postgres -c "createuser -s $POSTGRES_USER"
sudo su - postgres -c "createdb $DB_NAME --owner $POSTGRES_USER"
sudo -u postgres psql -c "ALTER USER $POSTGRES_USER WITH PASSWORD '$POSTGRES_PASSWORD';"
sudo -u postgres psql -c "CREATE ROLE $USER WITH LOGIN PASSWORD '$POSTGRES_PASSWORD';"

echo "======= #12: Creating user for Linux ======="
sudo adduser --system --quiet --shell=/bin/bash --home=/home/$USER --gecos $USER --group $USER
gpasswd -a $USER sudo

echo "======= #13: Creating virtual environment for Python ======="
virtualenv /home/$USER/.venv --python=python3
source /home/$USER/.venv/bin/activate

echo "======= #14: Clone project from GitHub ======="
read -p 'URL del proyecto en GitHub (dejar en blanco para usar la carpeta actual): ' GIT_URL

read -p 'Nombre de la carpeta del proyecto (MyFolder): ' FOLDER_NAME
read -p 'Nombre de la App principal (MyApp): ' APP_NAME

ROOT_PATH=/home/$USER
PROJECT_PATH=$ROOT_PATH/$FOLDER_NAME
APP_PATH=$PROJECT_PATH/$APP_NAME

if ! [ -z "$GIT_URL" ]; then
    git -C /home/$USER clone $GIT_URL
else
    echo "======= #15: Copying project from current folder ======="
    cp -r $LOCAL_PATH $PROJECT_PATH
fi

echo "======= #15.5 Custome path for project ======="
echo "Estructura de carpetas por defecto de Django (MyFolder/MyApp)"
echo "Tu proyecto tiene otra estructura de carpetas? (ejemplo: MyFolder/Other/Folder/MyApp)"
echo "Nota: Dejar en blanco si no es el caso"
read -p 'Ingresa las carpetas que se encuentran entre MyFolder y MyApp (ejemplo: Other/Folder): ' CUSTOM_PROJECT_PATH

if ! [ -z "$CUSTOM_PROJECT_PATH" ]; then
    APP_PATH=$PROJECT_PATH/$CUSTOM_PROJECT_PATH/$APP_NAME
fi
echo "======= #16: Installing dependencies for project ======="
pip install -q -r $PROJECT_PATH/requirements.txt

echo "======= #17: Installing Gunicorn ======="
pip install -q gunicorn

echo "======= #18: Creating Gunicorn service ======="
# Valide if exist a custom path or not Line 118

if [ -z "$CUSTOM_PROJECT_PATH" ]; then
   PATH_TO_GUNICORN_START=$PROJECT_PATH
else
    PATH_TO_GUNICORN_START=$PROJECT_PATH/$CUSTOM_PROJECT_PATH
fi

sudo tee $ROOT_PATH/.venv/bin/gunicorn_start<<EOF
#!/bin/bash
NAME=$APP_NAME
DIR=$PATH_TO_GUNICORN_START
USER=$USER
GROUP=$USER
WORKERS=3
BIND=unix:$PROJECT_PATH/gunicorn.sock
DJANGO_SETTINGS_MODULE=$APP_NAME.settings
DJANGO_WSGI_MODULE=$APP_NAME.wsgi
LOG_LEVEL=error

source $ROOT_PATH/.venv/bin/activate

export DJANGO_SETTINGS_MODULE=\$DJANGO_SETTINGS_MODULE
export PYTHONPATH=\$DIR:\$PYTHONPATH

exec $ROOT_PATH/.venv/bin/gunicorn \${DJANGO_WSGI_MODULE}:application \
  --name \$NAME \
  --workers \$WORKERS \
  --user=\$USER --group=\$GROUP \
  --bind=\$BIND \
  --log-level=\$LOG_LEVEL \
  --log-file=-
EOF

sudo chmod +x $ROOT_PATH/.venv/bin/gunicorn_start

echo "======= #19: Convert Gunicorn start to executable ======="
chmod u+x $ROOT_PATH/.venv/bin/gunicorn_start

echo "======= #20: Configure Supervisor to run Gunicorn ======="
mkdir -p $ROOT_PATH/Logs
touch $ROOT_PATH/Logs/gunicorn-error.log

# Validate if file exists to not override if execute again
if ! [ -e "/etc/supervisor/conf.d/django_app.conf" ]; then
    touch /etc/supervisor/conf.d/django_app.conf
    sudo tee /etc/supervisor/conf.d/django_app.conf<<EOF
    [program:django_app]
    command = $ROOT_PATH/.venv/bin/gunicorn_start
    user = $USER
    auto_start = true
    autorestart = true
    redirect_stderr = true
    stdout_logfile = $ROOT_PATH/Logs/gunicorn-error.log
EOF
fi

sudo supervisorctl reread
sudo supervisorctl update

echo "======= #21: Configure Nginx to run Gunicorn ======="

if ! [ -e "/etc/nginx/sites-available/$APP_NAME" ]; then
  touch /etc/nginx/sites-available/$APP_NAME

  read -p 'IP del servidor: ' SERVER_IP

  if [ -z "$CUSTOM_PROJECT_PATH" ]; then
    PATH_TO_NGINX_STATICFILE=$PROJECT_PATH
  else
    PATH_TO_NGINX_STATICFILE=$PROJECT_PATH/$CUSTOM_PROJECT_PATH
  fi

  sudo tee /etc/nginx/sites-available/$APP_NAME<<EOF
  upstream django_app {
    server unix:$PROJECT_PATH/gunicorn.sock fail_timeout=0;
  }

  server {
    listen 80;
    server_name $SERVER_IP;

    keepalive_timeout 5;
    client_max_body_size 4G;

    access_log $ROOT_PATH/Logs/nginx-access.log;
    error_log $ROOT_PATH/Logs/nginx-error.log;

    location /static/ {
      alias $PATH_TO_NGINX_STATICFILE/staticfiles/;
    }

    location / {
      try_files \$uri @proxy_to_app;
    }

    location @proxy_to_app {
      proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
      proxy_set_header Host \$http_host;
      proxy_redirect off;
      proxy_pass http://django_app;
    }
  }
EOF
fi

sudo ln -s /etc/nginx/sites-available/$APP_NAME /etc/nginx/sites-enabled/$APP_NAME
sudo rm /etc/nginx/sites-enabled/default
sudo service nginx restart

echo "======= #22: Django last steps ======="

if ! [ -z "$CUSTOM_PROJECT_PATH" ]; then
  python3 $PROJECT_PATH/$CUSTOM_PROJECT_PATH/manage.py migrate
  python3 $PROJECT_PATH/$CUSTOM_PROJECT_PATH/manage.py collectstatic

else
  python3 $PROJECT_PATH/manage.py migrate
  python3 $PROJECT_PATH/manage.py collectstatic
fi

echo "======= #23: Assign permissions django user to project folder ======="
sudo chown -R $USER:$USER $ROOT_PATH/*

echo "======= #24: Restart Supervisor ======="
sudo supervisorctl restart django_app

echo "======= #25: Finished! ======="
echo "Your project is running at http://$SERVER_IP"
echo "Script by DiegoDG (https://diegodg.com.mx)"