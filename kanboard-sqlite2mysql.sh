#!/usr/bin/env bash

readonly PROGNAME=$(basename $0)
readonly PROGDIR=$(readlink -m $(dirname $0))
readonly ARGS="$@"

usage()
{
	cat <<- EOF
	usage: $PROGNAME <Kanboard instance physical path> [ <MySQL DB name> -h <MySQL DB host> -u <MySQL DB user> -p ] [ --help ]

	 -p, --password		MySQL database password. If password is not given it's asked from the tty.
	 -h, --host		MySQL database host
	 -u, --user		MySQL database user for login
	 -o, --output		Path to the output SQL dump compatible with MySQL
	 -H, --help		Display this help
	 -v, --version		Display the Kanboard SQLite2MySQL version

	Example:
	 $PROGNAME /usr/local/share/www/kanboard -o db-mysql.sql
	 $PROGNAME /usr/local/share/www/kanboard kanboard -u root --password root
	EOF
}

version()
{
	cat <<- EOF
	Kanboard SQLite2MySQL 0.0.1
	Migrate your SQLite Kanboard database to MySQL in one go! By Olivier.
	EOF
}

cmdline()
{
  KANBOARD_PATH=
  DB_HOSTNAME=
  DB_USERNAME=
  DB_PASSWORD=
  DB_NAME=
  OUTPUT_FILE=db-mysql.sql
  if [ "$#" -lt "1" ]; then
    echo 'error: missing arguments'
    usage
    exit -1
  fi
  while [ "$1" != "" ]; do
  case $1 in
    -o | --output )
      shift
      OUTPUT_FILE=$1
      shift
      ;;
    -h | --host )
      shift
      DB_HOSTNAME=$1
      shift
      ;;
    -u | --user )
      shift
      DB_USERNAME=$1
      shift
      ;;
    -p )
      shift
      echo 'Enter password: '
      read DB_PASSWORD
      ;;
    --password )
      shift
      DB_PASSWORD=$1
      shift
      ;;
    -H | --help )
      usage
      exit 0
      ;;
    -v | --version )
      version
      exit 0
      ;;
    *)
      if [ "${KANBOARD_PATH}" == ""  ]; then
        if [ ! -d "$1" ]; then
          echo "error: unknown path '$1'"
          usage
          exit -1
        fi
        KANBOARD_PATH=$1
        shift
      elif [ "$DB_NAME" == ""  ]; then
        DB_NAME=$1
        shift
      else
        echo "error: unknwon argument '$1'"
        usage
        exit -1
      fi
      ;;
  esac
  done
  
  if [ ! "${DB_NAME}" == "" ]; then
    if [ "${DB_USERNAME}" == "" ]; then
        DB_USERNAME=root
    fi
    if [ "${DB_HOSTNAME}" == "" ]; then
        DB_HOSTNAME=localhost
    fi
  fi
  return 0
}

# List tables names of a SQLite database
# 'sqlite3 db.sqlite .tables' already return tables names but only in column mode...
# * @param Database file
sqlite_tables()
{
    local sqliteDbFile=$1
    sqlite3 ${sqliteDbFile} .schema \
        | sed -e '/[^C(]$/d' -e 's/CREATE TABLE \([a-z_]*\).*/\1/' -e '/^$/d'
}

# List column names of a SQLite table
# * @param Database file
# * @param Table name
sqlite_columns()
{
    local sqliteDbFile=$1
    local table=$2
    sqlite3 -csv -header ${sqliteDbFile} "select * from ${table};" \
        | head -n 1 \
        | sed -e 's/,/`,`/g' -e 's/^/`/' -e 's/$/`/'
}

# Generate "INSERT INTO" queries to dump data of an SQLite table
# * @param Database file
# * @param Table name
sqlite_dump_table_data()
{
    local sqliteDbFile=$1
    local table=$2
    local columns=`sqlite_columns ${sqliteDbFile} ${table}`
    echo -e ".mode insert ${table}\nselect * from ${table};" \
        | sqlite3 ${sqliteDbFile} \
        | sed -e "s/INSERT INTO \([a-z_]*\)/INSERT INTO \1 (${columns})/"
}

# Generate "INSERT INTO" queries to dump data of a SQLite database
# * @param Database file
sqlite_dump_data()
{
    local sqliteDbFile=$1
    local prioritizedTables='projects columns links groups users tasks task_has_links subtasks comments actions'
    for t in $prioritizedTables; do
        sqlite_dump_table_data ${sqliteDbFile} ${t}
    done
    for t in $(sqlite_tables ${sqliteDbFile} | grep -v -e projects -e columns -e links -e groups -e users -e tasks -e task_has_links -e subtasks -e comments -e actions); do
        sqlite_dump_table_data ${sqliteDbFile} ${t}
    done
}

createMysqlDump()
{
    local sqliteDbFile=$1
    
    echo 'ALTER TABLE users ADD COLUMN is_admin INT DEFAULT 0;
ALTER TABLE users ADD COLUMN default_project_id INT DEFAULT 0;
ALTER TABLE users ADD COLUMN is_project_admin INT DEFAULT 0;
ALTER TABLE tasks ADD COLUMN estimate_duration VARCHAR(255) DEFAULT "";
ALTER TABLE tasks ADD COLUMN actual_duration VARCHAR(255) DEFAULT "";
ALTER TABLE project_has_users ADD COLUMN id INT DEFAULT 0;
ALTER TABLE project_has_users ADD COLUMN is_owner INT DEFAULT 0;
SET FOREIGN_KEY_CHECKS = 0;
TRUNCATE TABLE settings;
TRUNCATE TABLE users;
TRUNCATE TABLE links;
TRUNCATE TABLE plugin_schema_versions;
SET FOREIGN_KEY_CHECKS = 1;' > ${OUTPUT_FILE}
    
    sqlite_dump_data ${sqliteDbFile} >> ${OUTPUT_FILE}
    
    echo 'ALTER TABLE users DROP COLUMN is_admin;
    ALTER TABLE users DROP COLUMN default_project_id;
    ALTER TABLE users DROP COLUMN is_project_admin;
    ALTER TABLE tasks DROP COLUMN estimate_duration;
    ALTER TABLE tasks DROP COLUMN actual_duration;
    ALTER TABLE project_has_users DROP COLUMN id;
    ALTER TABLE project_has_users DROP COLUMN is_owner;' >> ${OUTPUT_FILE}
    
    cat ${OUTPUT_FILE} \
        | sed -e 's/\\/\//g' \
        | sed -e 's/\/Kanboard\/Action\//\\\\Kanboard\\\\Action\\\\/g' \
        | sed -e 's/\/u00/\\\\u00/g' \
        > db.mysql
    mv db.mysql ${OUTPUT_FILE}
}

generateMysqlSchema()
{
    mv ${KANBOARD_PATH}/config.php ${KANBOARD_PATH}/config_tmp.php
    export DATABASE_URL="mysql://${DB_USERNAME}:${DB_PASSWORD}@${DB_HOSTNAME}/${DB_NAME}"
    php ${KANBOARD_PATH}/app/common.php
    mv ${KANBOARD_PATH}/config_tmp.php ${KANBOARD_PATH}/config.php
}

fillMysqlDb()
{
    mysql -h ${DB_HOSTNAME} -u ${DB_USERNAME} --password=${DB_PASSWORD} ${DB_NAME} \
        < ${OUTPUT_FILE}
}

main()
{
    cmdline $ARGS
    local sqliteDbFile=${KANBOARD_PATH}/data/db.sqlite
    
    echo '# Create MySQL data dump from SQLite database'
    createMysqlDump ${sqliteDbFile} \
        && (echo "done" ; echo "check ${OUTPUT_FILE}") \
        || (echo 'FAILLURE' ; exit -1)

    if [ ! "${DB_NAME}" == "" ]; then
        echo '# Generate schema in the MySQL database using Kanboard'
        generateMysqlSchema \
            && echo "done" \
            || (echo 'FAILLURE' ; exit -1)

        echo '# Fill the MySQL database with the SQLite database data'
        fillMysqlDb \
            && echo "done" \
            || (echo 'FAILLURE' ; exit -1)
    fi
}
main