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
#!/usr/bin/env bash
CONDA_PREFIX=\$(readlink -f \${CONDA_PREFIX:-\$(dirname \$0)../../../)})
DATA_DIR=\${API_DATA_DIR:-$PREFIX/var/$PKG_NAME/mysqldb}
LOG_DIR=\${API_LOG_DIR:-$PREFIX/var/log/$PKG_NAME}

set  -o nounset -o pipefail -o errexit
mkdir -p \$LOG_DIR \$DATA_DIR
temp_dir=\$(mktemp -d)
USER=\$(whoami)
trap '$PREFIX/bin/mysql.server stop' SIGINT SIGTERM ERR
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

if [ ! -d \$DATA_DIR/mysql ];then
    $PREFIX/bin/mysqld --no-defaults --datadir=\$DATA_DIR --initialize-insecure --user=\$USER
fi
$PREFIX/bin/mysqld --no-defaults --datadir=\$DATA_DIR --user=\$USER --skip-grant-tables --skip-networking --init-file=\$temp_dir/init.sql &
MYSQLD_PID=\$!
sleep 5
$PREFIX/bin/mysql.server stop
if [[ -n \$MYSQLD_PID ]];then
    kill \$MYSQLD_PID &> /dev/null || true
fi
rm -fr \$temp_dir
EOF
    chmod +x $PREFIX/libexec/$PKG_NAME/scripts/init-mysql
}

create_solr_unit(){
    # Init the apache solr
    cat << EOF > $PREFIX/libexec/$PKG_NAME/scripts/init-solr
#!/usr/bin/env bash
CONDA_PREFIX=\$(readlink -f \${CONDA_PREFIX:-\$(dirname \$0)../../../)})
DATA_DIR=\${API_DATA_DIR:-$PREFIX/var/$PKG_NAME/solr}
set  -o nounset -o pipefail -o errexit
temp_dir=\$(mktemp -d)
trap 'rm -rf "\$temp_dir"' EXIT
mkdir -p \${DATA_DIR}
SOLR_PORT=\${API_SOLR_PORT:-8983}
SOLR_HEAP=\${API_SOLR_HEAP:-4g}
SOLR_CORE=\${API_SOLR_CORE:-files}
trap "$PREFIX/bin/solr stop -p \$SOLR_PORT" SIGINT SIGTERM ERR
configure_solr=false
is_solr_running(){
     curl -s "http://localhost:\$1/solr/admin/info/system"| grep -q "solr_home"
}
for core in \$SOLR_CORE latest;do
    if [ ! -f "\$DATA_DIR/\$core/core.properties" ];then
        configure_solr=true
    fi
    if \$configure_solr ;then
        if ! is_solr_running \$SOLR_PORT ;then
            echo "Starting Solr on port \$SOLR_PORT ..."
            $PREFIX/bin/solr start \
                --force -m \$SOLR_HEAP -s \${DATA_DIR} \
                -p \$SOLR_PORT -q --no-prompt &> \$temp_dir/solr.log &
            timeout 20 bash -c 'until curl -s http://localhost:'"\$SOLR_PORT"'/solr/admin/ping;do sleep 2; done' ||{
                echo "Error: Solr did not start within 60 seconds." >&2
                cat \$temp_dir/solr.log >&2
            }
        fi
        echo "Creating core \$core ..."
        $PREFIX/bin/solr create -c \$core --solr-url http://localhost:\$SOLR_PORT
        cp $PREFIX/share/$PKG_NAME/solr/*.{txt,xml} \$DATA_DIR/\$core/conf
        curl http://localhost:\$SOLR_PORT/solr/\$core/config -d '{"set-user-property": {"update.autoCreateFields":"false"}}'
    fi
done
if \$configure_solr ;then
    $PREFIX/bin/solr stop -p \$SOLR_PORT
fi
EOF
chmod +x $PREFIX/libexec/$PKG_NAME/scripts/init-solr
}

create_mongo_unit(){
    cat << EOF > $PREFIX/libexec/$PKG_NAME/scripts/init-mongo
#!/usr/bin/env bash
CONDA_PREFIX=\$(readlink -f \${CONDA_PREFIX:-\$(dirname \$0)../../../)})
DATA_DIR=\${API_DATA_DIR:-$PREFIX/var/$PKG_NAME/monogodb}
LOG_DIR=\${API_LOG_DIR:-$PREFIX/var/log/$PKG_NAME}
CONFIG_DIR=$PREFIX/share/$PKG_NAME/mongodb
set  -o nounset -o pipefail -o errexit
mkdir -p \$LOG_DIR \$DATA_DIR \$CONFIG_DIR
API_MONGO_HOST=\${API_MONGO_HOST:-localhost:27017}
API_MONGO_DB=\${API_MONGO_DB:-search_stats}
trap '$PREFIX/bin/mongod -f \$CONFIG_DIR --shutdown' SIGINT SIGTERM ERR
temp_dir=\$(mktemp -d)
cat <<EOI > \$CONFIG_DIR/mongod.yaml
# MongoDB Configuration File

# Where to store data.
storage:
  dbPath: \$DATA_DIR
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
  pidFilePath: \$CONFIG_DIR/mongod.pid  # Location of the process ID file.

# Logging.
systemLog:
  destination: file
  logAppend: true
  path: \$LOG_DIR/mongod.log
EOI

cat    << EOI > \$temp_dir/init_mongo.py
import os
from pymongo import MongoClient
from pymongo.errors import OperationFailure

client = MongoClient("\$API_MONGO_HOST")
client["\$API_MONGO_DB"]
db = client["admin"]
try:
    db.command("dropUser", "\$API_MONGO_USER")
except OperationFailure as e:
    pass
try:
    db.command(
        "createUser", "\$API_MONGO_USER",
        pwd="\$API_MONGO_PASSWORD",
        roles=["userAdminAnyDatabase","readWriteAnyDatabase" ],
    )
except Exception as e:
    print('Failed to create user {}: {}'.format("\$API_MONGO_USER", e))
    raise
EOI
$PREFIX/bin/mongod -f \$CONFIG_DIR/mongod.yaml --noauth --fork
sleep 5
$PREFIX/bin/python \$temp_dir/init_mongo.py
$PREFIX/bin/mongod -f \$CONFIG_DIR/mongod.yaml --shutdown &
rm -fr \$temp_dir
EOF
chmod +x $PREFIX/libexec/$PKG_NAME/scripts/init-mongo
}


create_opensearch_unit() {
    # Create the OpenSearch initialization script
    cat << EOF > $PREFIX/libexec/$PKG_NAME/scripts/init-opensearch
#!/usr/bin/env bash
CONDA_PREFIX=\$(readlink -f \${CONDA_PREFIX:-\$(dirname \$0)../../../)})
export OPENSEARCH_HOME=$PREFIX/libexec/opensearch
export JAVA_HOME=$PREFIX
set -o nounset -o pipefail -o errexit

# Set OpenSearch environment variables
export OPENSEARCH_PATH_CONF=\$OPENSEARCH_HOME/config
PATH="$PREFIX/libexec/opensearch/bin:\$PATH"

# Install plugin security to be able to disable SSL
if [ ! -d "\$OPENSEARCH_HOME/plugins/opensearch-security" ];then
    mkdir -p \$OPENSEARCH_HOME/{plugins,config}
    opensearch-plugin install --batch https://repo1.maven.org/maven2/org/opensearch/plugin/opensearch-security/2.19.1.0/opensearch-security-2.19.1.0.zip
fi
# Installing OpenSearch job scheduler plugin (dependency of ISM)
if [ ! -d "\$OPENSEARCH_HOME/plugins/opensearch-job-scheduler" ];then
    opensearch-plugin install --batch https://repo1.maven.org/maven2/org/opensearch/plugin/opensearch-job-scheduler/2.19.1.0/opensearch-job-scheduler-2.19.1.0.zip
fi
# Install OpenSearch Index Management plugin
if [ ! -d "\$OPENSEARCH_HOME/plugins/opensearch-index-management" ];then
    opensearch-plugin install --batch https://repo1.maven.org/maven2/org/opensearch/plugin/opensearch-index-management/2.19.1.0/opensearch-index-management-2.19.1.0.zip
fi

cp $PREFIX/share/$PKG_NAME/opensearch/opensearch.yml \$OPENSEARCH_PATH_CONF
EOF
    chmod +x $PREFIX/libexec/$PKG_NAME/scripts/init-opensearch
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
    -e "s|{{EXEC_START_PRE}}|$PREFIX/libexec/$PKG_NAME/scripts/init-mysql |g" \
    -e "s|{{EXEC_START}}|$PREFIX/bin/mysqld --no-defaults --datadir=\$API_DATA_DIR/mysqldb --bind-address=0.0.0.0|g")
    echo "$mysql_unit" | tee "$PREFIX/share/$PKG_NAME/systemd/mysqld.service" > /dev/null

    #APACHE SOLR
    solr_unit=$(cat template.j2|sed \
    -e "s|{{DESCRIPTION}}|Apache solr server|g" \
    -e "s|{{AFTER}}|network.target|g" \
    -e "s|{{EXEC_START_PRE}}|$PREFIX/libexec/$PKG_NAME/scripts/init-solr |g" \
    -e "s|{{EXEC_START}}|$PREFIX/bin/solr start -s \$API_DATA_DIR/solr -f --force |g")
    echo "$solr_unit" | tee "$PREFIX/share/$PKG_NAME/systemd/solr.service" > /dev/null


    #MONGO DB
    mongo_unit=$(cat template.j2|sed \
    -e "s|{{DESCRIPTION}}|MongoDB server|g" \
    -e "s|{{AFTER}}|network.target|g" \
    -e "s|{{EXEC_START_PRE}}|$PREFIX/libexec/$PKG_NAME/scripts/init-mongo |g" \
    -e "s|{{EXEC_START}}|$PREFIX/bin/mongod -f $PREFIX/share/$PKG_NAME/mongodb/mongod.yaml |g")
    echo "$mongo_unit" | tee "$PREFIX/share/$PKG_NAME/systemd/mongo.service" > /dev/null


    #Redis
    redis_unit=$(cat template.j2|sed \
    -e "s|{{DESCRIPTION}}|Redis server|g" \
    -e "s|{{AFTER}}|network.target|g" \
    -e "s|{{EXEC_START_PRE}}|$PREFIX/libexec/$PKG_NAME/scripts/init-redis|g" \
    -e "s|{{EXEC_START}}|$PREFIX/bin/redis-server /tmp/redis.conf|g")
    echo "$redis_unit" | tee "$PREFIX/share/$PKG_NAME/systemd/redis.service" > /dev/null

    #OPENSEARCH - STACAPI
    opensearch_unit=$(cat template.j2|sed \
    -e "s|{{DESCRIPTION}}|OpenSearch server|g" \
    -e "s|{{AFTER}}|network.target|g" \
    -e "s|{{EXEC_START_PRE}}|$PREFIX/libexec/$PKG_NAME/scripts/init-opensearch |g" \
    -e "s|{{EXEC_START}}|$PREFIX/bin/opensearch |g")
    echo "$opensearch_unit" | tee "$PREFIX/share/$PKG_NAME/systemd/opensearch.service" > /dev/null

}

create_redis_unit(){
    mkdir -p $PREFIX/libexec/$PKG_NAME/scripts/
    redis_init=$(cat freva-service-config/redis/redis-cmd.sh |grep -v redis-server|grep -v 'cat /tmp/redis.conf'|sed\
    -e "s|REDIS_PASSWORD|API_REDIS_PASSWORD|g" \
    -e "s|REDIS_USERNAME|API_REDIS_USER|g" \
    -e "s|REDIS_SSL_CERTFILE|API_REDIS_SSL_CERTFILE|g" \
    -e "s|REDIS_SSL_KEYFILE|API_REDIS_SSL_KEYFILE|g" \
    -e "s|REDIS_LOGLEVEL|API_REDIS_LOGLEVEL|g")
    echo "$redis_init" | tee "$PREFIX/libexec/$PKG_NAME/scripts/init-redis" > /dev/null
    echo "mkdir -p  \${API_DATA_DIR:-$PREFIX/var/$PKG_NAME}/redis" >> $PREFIX/libexec/$PKG_NAME/scripts/init-redis
    echo "mkdir -p  \${API_LOG_DIR:-$PREFIX/var/log/$PKG_NAME}" >> $PREFIX/libexec/$PKG_NAME/scripts/init-redis
    echo "echo dir \${API_DATA_DIR:-$PREFIX/var/$PKG_NAME}/redis >> /tmp/redis.conf" >> $PREFIX/libexec/$PKG_NAME/scripts/init-redis
    echo "echo logfile \${API_LOG_DIR:-$PREFIX/var/log/$PKG_NAME}/redis.log >> /tmp/redis.conf" >> $PREFIX/libexec/$PKG_NAME/scripts/init-redis
    echo "cat /tmp/redis.conf" >> $PREFIX/libexec/$PKG_NAME/scripts/init-redis
    chmod +x $PREFIX/libexec/$PKG_NAME/scripts/init-redis
}

setup_config() {
    # Setup additional configuration
    cd $TEMP_DIR
    git clone --recursive https://github.com/FREVA-CLINT/freva-service-config.git
    mkdir -p $PREFIX/libexec/$PKG_NAME/scripts
    mkdir -p $PREFIX/share/$PKG_NAME/{mysqld,mongodb}
    mkdir -p $PREFIX/var/log/$PKG_NAME
    mkdir -p $PREFIX/var/$PKG_NAME/{mongodb,mysqld,solr,redis,opensearch}
    cp -r freva-service-config/solr $PREFIX/share/$PKG_NAME/
    cp -r freva-service-config/mysql/*.{sql,sh} $PREFIX/share/$PKG_NAME/mysqld/
    cp -r freva-service-config/opensearch $PREFIX/share/$PKG_NAME/
    create_mysql_unit
    create_solr_unit
    create_mongo_unit
    create_redis_unit
    create_opensearch_unit
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
API_OIDC_CLIENT_ID=
API_OIDC_DISCOVERY_URL=
API_REDIS_HOST=
API_REDIS_PASSWORD=
API_REDIS_USER=
API_REDIS_SSL_CERTFILE=
API_REDIS_SSL_KEYFILE=
API_MONGO_HOST=localhost:27017
API_MONGO_USER=
API_MONGO_PASSWORD=
API_MONGO_DB=search_stats
\n#Opensearch settings' > $PREFIX/share/$PKG_NAME/config.ini
echo "JAVA_HOME=$PREFIX" >> $PREFIX/share/$PKG_NAME/config.ini
echo "OPENSEARCH_HOME=$PREFIX/libexec/opensearch" >> $PREFIX/share/$PKG_NAME/config.ini
echo "OPENSEARCH_PATH_CONF=$PREFIX/libexec/opensearch/config" >> $PREFIX/share/$PKG_NAME/config.ini
chmod 600 $PREFIX/share/$PKG_NAME/config.ini
}


install_server
setup_config
exit_func 0
