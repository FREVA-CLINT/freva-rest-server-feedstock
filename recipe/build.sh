#!/usr/bin/env bash
set  -o nounset -o pipefail -o errexit

TEMP_DIR=$(mktemp -d)
PKG_NAME=freva-rest-server

# Define an exit function
exit_func(){
    rm -rf $TEMP_DIR
    exit $1
}

# Trap exit signals to ensure cleanup is called
trap 'exit_func 1' SIGINT SIGTERM ERR

create_mysql_unit(){
    cat << EOF > $PREFIX/libexec/$PKG_NAME/scripts/init-mysql
#!/usr/bin/env sh
set  -o nounset
CONDA_PREFIX=\$(readlink -f \${CONDA_PREFIX:-\$(dirname \$0)../../../)})

temp_dir=\$(mktemp -d)

cat    << EOI > \$temp_dir/init.sql
USE mysql;

-- Set root passwords
FLUSH PRIVILEGES;
ALTER USER 'root'@'localhost' IDENTIFIED BY '\$MYSQL_ROOT_PASSWORD';

-- reset and set user password
DROP USER IF EXISTS '\$MYSQL_USER'@'%';
DROP USER IF EXISTS '\$MYSQL_USER'@'localhost';
CREATE USER '\$MYSQL_USER'@'%' IDENTIFIED BY '\$MYSQL_PASSWORD';
CREATE USER '\$MYSQL_USER'@'localhost' IDENTIFIED BY '\$MYSQL_PASSWORD';

-- Create database if it doesn't exist
CREATE DATABASE IF NOT EXISTS \\\`\$MYSQL_DATABASE\\\`;

-- Grant privileges
GRANT ALL PRIVILEGES ON \\\`\$MYSQL_DATABASE\\\`.* TO '\$MYSQL_USER'@'%';
GRANT ALL PRIVILEGES ON \\\`\$MYSQL_DATABASE\\\`.* TO '\$MYSQL_USER'@'localhost';

FLUSH PRIVILEGES;
USE \\\`\$MYSQL_DATABASE\\\`;

EOI
cat $PREFIX/share/$PKG_NAME/mysqld/create_tables.sql >> \$temp_dir/init.sql

if [ ! -d $PREFIX/data ];then
    $PREFIX/bin/mysqld --initialize-insecure
fi
$PREFIX/bin/mysqld --skip-grant-tables --skip-networking --init-file=\$temp_dir/init.sql &
MYSQLD_PID=\$!
sleep 5
kill -9 \$MYSQLD_PID
rm -fr \$temp_dir
EOF
    chmod +x $PREFIX/libexec/$PKG_NAME/scripts/init-mysql
}

create_solr_unit(){
    # Init the apache solr
    cat << EOF > $PREFIX/libexec/$PKG_NAME/scripts/init-solr
#!/usr/bin/env sh
set  -o nounset
SOLR_PORT=\${API_SOLR_PORT:-8983}
SOLR_HEAP=\${API_SOLR_HEAP:-4g}
SOLR_CORE=\${API_SOLR_CORE:-files}
CONDA_PREFIX=\$(readlink -f \${CONDA_PREFIX:-\$(dirname \$0)../../../)})

for core in \$SOLR_CORE latest;do
    if [ ! -d "$PREFIX/libexec/apache-solr/server/solr/\$core" ];then
        $PREFIX/bin/solr -m \$SOLR_HEAP -p \$SOLR_PORT -q --no-prompt
        $PREFIX/bin/solr create -c \$core --solr-url http://localhost:\$SOLR_PORT
        $PREFIX/bin/solr stop -p \$SOLR_PORT
    fi
    cp $PREFIX/share/$PKG_NAME/solr/*.{txt,xml} $PREFIX/libexec/apache-solr/server/solr/\$core/conf
done

EOF
chmod +x $PREFIX/libexec/$PKG_NAME/scripts/init-solr
}

create_mongo_unit(){
    cat << EOF > $PREFIX/libexec/$PKG_NAME/scripts/init-mongo
#!/usr/bin/env sh
set  -o nounset
API_MONGO_HOST=\${API_MONGO_HOST:-localhost:27017}
API_MONGO_DB=\${API_MONGO_DB:-search_stats}
CONDA_PREFIX=\$(readlink -f \${CONDA_PREFIX:-\$(dirname \$0)../../../)})
temp_dir=\$(mktemp -d)
if [ -z "\$(cat $PREFIX/share/$PKG_NAME/mongodb/mongod.yaml)" ];then
    cat <<EOI > $PREFIX/share/$PKG_NAME/mongodb/mongod.yaml
# MongoDB Configuration File

# Where to store data.
storage:
  dbPath: $PREFIX/var/$PKG_NAME/data/mongodb
  journal:
    enabled: true
# Network interfaces.
net:
  port: 27017
  bindIp: 0.0.0.0

# Security settings.
security:
  authorization: enabled  # Enables role-based access control.

# Process management.
processManagement:
  fork: true  # Run the MongoDB server as a daemon.
  pidFilePath: $PREFIX/var/mongodb/mongod.pid  # Location of the process ID file.

# Logging.
systemLog:
  destination: file
  logAppend: true
  path: $PREFIX/var/log/mongodb/mongod.log
EOI
fi

cat    << EOI > \$temp_dir/init_mongo.py
import os
from pymongo import MongoClient
from pymongo.errors import OperationFailure

client = MongoClient("\$API_MONGO_HOST")
db = client["\$API_MONGO_DB"]
try:
    db.command("dropUser", "\$API_MONGO_USER")
except OperationFailure as e:
    pass
try:
    db.command(
        "createUser", "\$API_MONGO_USER",
        pwd="\$API_MONGO_PASSWORD",
        roles=[{"role": "readWrite", "db": "\$API_MONGO_DB"}]
    )
except Exception as e:
    print('Failed to create user {}: {}'.format("\$API_MONGO_USER", e))
    raise
EOI
$PREFIX/bin/mongod -f $PREFIX/share/$PKG_NAME/mongodb/mongod.yaml --noauth --fork
sleep 5
$PREFIX/bin/python \$temp_dir/init_mongo.py
$PREFIX/bin/mongod -f $PREFIX/share/$PKG_NAME/mongodb/mongod.yaml --shutdown
rm -fr \$temp_dir
EOF
chmod +x $PREFIX/libexec/$PKG_NAME/scripts/init-mongo
touch $PREFIX/share/$PKG_NAME/mongodb/mongod.yaml
}

install_server(){
    # Install the rest server
    #
    $PREFIX/bin/python -m pip install ./freva-rest -vv --prefix $PREFIX \
        --root-user-action ignore --no-deps --no-build-isolation

}

create_systemd_units(){
    # Create service units.
    #
    cat << EOF > template.j2
[Unit]
Description={{DESCRIPTION}}
After={{AFTER}}

[Service]
Type=notify
ProtectSystem=full
PermissionsStartOnly=true
NoNewPrivileges=true
ProtectHome=true
KillSignal=SIGTERM
SendSIGKILL=no
Restart=on-abort
ExecStartPre=/bin/sh -c "systemctl unset-environment _WSREP_START_POSITION"
ExecStartPre={{EXEC_START_PRE}}
ExecStart={{EXEC_START}}
ExecStartPost=/bin/sh -c "systemctl unset-environment _WSREP_START_POSITION"
UMask=007

# Uncomment the following line to fine grain the sytemd unit behaviour
#
# Set the user name and user group
# User=
# Group=
#
# Set an environment file with default configuration
EnvironmentFile=$PREFIX/share/$PKG_NAME/config.ini
[Install]
WantedBy=multi-user.target
EOF
    mkdir -p $PREFIX/share/$PKG_NAME/systemd/
    #MYSQL SERVER
    mysql_unit=$(cat template.j2|sed \
    -e "s|{{DESCRIPTION}}|MariaDB database server|g" \
    -e "s|{{AFTER}}|network.target|g" \
    -e "s|{{EXEC_START_PRE}}|$PREFIX/libexec/$PKG_NAME/scripts/init-mysqld |g" \
    -e "s|{{EXEC_START}}|$PREFIX/bin/mysqld |g")
    echo "$mysql_unit" | tee "$PREFIX/share/$PKG_NAME/systemd/mysqld.service" > /dev/null

    #APACHE SOLR
    solr_unit=$(cat template.j2|sed \
    -e "s|{{DESCRIPTION}}|Apache solr server|g" \
    -e "s|{{AFTER}}|network.target|g" \
    -e "s|{{EXEC_START_PRE}}|$PREFIX/libexec/$PKG_NAME/scripts/init-solr |g" \
    -e "s|{{EXEC_START}}|$PREFIX/bin/solr -f --force |g")
    echo "$solr_unit" | tee "$PREFIX/share/$PKG_NAME/systemd/solr.service" > /dev/null


    #MONGO DB
    mongo_unit=$(cat template.j2|sed \
    -e "s|{{DESCRIPTION}}|MongoDB server|g" \
    -e "s|{{AFTER}}|network.target|g" \
    -e "s|{{EXEC_START_PRE}}|$PREFIX/libexec/$PKG_NAME/scripts/init-mongo |g" \
    -e "s|{{EXEC_START}}|$PREFIX/bin/mongod -f \$CONDA_PREFIX/share/$PKG_NAME/mongodb/mongod.conf |g")
    echo "$mongo_unit" | tee "$PREFIX/share/$PKG_NAME/systemd/mongo.service" > /dev/null


    #Redis
    redis_unit=$(cat template.j2|sed \
    -e "s|{{DESCRIPTION}}|Redis server|g" \
    -e "s|{{AFTER}}|network.target|g" \
    -e "s|{{EXEC_START_PRE}}||g" \
    -e "s|{{EXEC_START}}|$PREFIX/libexec/$PKG_NAME/scripts/init-redis|g")
    echo "$redis_unit" | tee "$PREFIX/share/$PKG_NAME/systemd/redis.service" > /dev/null

}


setup_config() {
    # Setup additional configuration
    cd $TEMP_DIR
    git clone --recursive https://github.com/FREVA-CLINT/freva-service-config.git
    mkdir -p $PREFIX/libexec/$PKG_NAME/scripts
    mkdir -p $PREFIX/share/$PKG_NAME/{mysqld,mongodb}
    mkdir -p $PREFIX/var/{mongodb,mysqld}
    mkdir -p $PREFIX/var/log/{mongodb,mysqld}
    mkdir -p $PREFIX/var/$PKG_NAME/data/{mongodb,mysqld}
    cp -r freva-service-config/solr $PREFIX/share/$PKG_NAME/
    cp -r freva-service-config/redis/redis-cmd.sh $PREFIX/libexec/$PKG_NAME/scripts/init-redis
    cp -r freva-service-config/mongo/* $PREFIX/share/$PKG_NAME/mongodb/
    cp -r freva-service-config/mysql/*.{sql,sh} $PREFIX/share/$PKG_NAME/mysqld/
    create_mysql_unit
    create_solr_unit
    create_mongo_unit
    create_systemd_units
    echo -e '# Mysql Server Settings.\n#
MYSQL_USER=
MYSQL_PASSWORD=
MYSQL_ROOT_PASSWORD=
MYSQL_DATABASE=
\n# Solr settings
API_SOLR_HEAP=4g
API_SOLR_PORT=8983
API_SOLR_CORE=files
\n# Rest API settings
API_PORT=7777
API_SOLR_HOST=localhost:8983
API_MONGO_HOST=localhost:27017
API_OIDC_CLIENT_ID=
API_OIDC_DISCOVERY_URL=
API_REDIS_HOST=
API_REDIS_SSL_CERTFILE=
API_REDIS_SSL_KEYFILE=
API_MONGO_USER=
API_MONGO_PASSWORD=
API_MONGO_DB=search_stats' > $PREFIX/share/$PKG_NAME/config.ini
}


install_server
setup_config
exit_func 0