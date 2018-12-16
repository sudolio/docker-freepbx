#!/bin/sh
set -e

wait_for_connection()
{
	printf "Waiting for $1 connection..."
	until nc -z -v -w30 $2 $3 >/dev/null 2>&1
	do
		sleep 1
	done
	printf "OK\n"
}

configure()
{
	[ -n "$DB_PASS" ] && PASS="-p$DB_PASS" || PASS=''

	cat >> /etc/odbc.ini <<- EOF
[MySQL-asteriskcdrdb]
Description = MariaDB connection to '$DB_NAME' database
Driver = MariaDB
Server = $DB_HOST
Database = $DB_NAME
User = $DB_USER
Password = $DB_PASS
Port = $DB_PORT
#Socket = /var/run/mysqld/mysqld.sock
Option = 3
EOF

	# configure tables in database
	set +e

	echo 'SELECT 1 FROM freepbx_settings LIMIT 1' | mysql -u$DB_USER $PASS -h$DB_HOST -P$DB_PORT $DB_NAME >/dev/null 2>&1
	if [ $? -eq 0 ]; then
		mysql -u$DB_USER $PASS -h$DB_HOST -P$DB_PORT $DB_NAME <<- EOF
			UPDATE freepbx_settings SET value = '$DB_HOST' WHERE keyword = 'CDRDBHOST';
			UPDATE freepbx_settings SET value = '$DB_NAME' WHERE keyword = 'CDRDBNAME';
			UPDATE freepbx_settings SET value = '$DB_PORT' WHERE keyword = 'CDRDBPORT';
		EOF
	fi

	echo 'SELECT 1 FROM sipsettings LIMIT 1' | mysql -u$DB_USER $PASS -h$DB_HOST -P$DB_PORT $DB_NAME >/dev/null 2>&1
	if [ $? -eq 0 ]; then
		mysql -u$DB_USER $PASS -h$DB_HOST -P$DB_PORT $DB_NAME <<- EOF
			INSERT INTO sipsettings (keyword, data, seq, type) VALUES ('rtpstart', '$RTP_PORT_START', 0, 0) ON DUPLICATE KEY UPDATE data = '$RTP_PORT_START';
			INSERT INTO sipsettings (keyword, data, seq, type) VALUES ('rtpend', '$RTP_PORT_END', 0, 0) ON DUPLICATE KEY UPDATE data = '$RTP_PORT_END';

			INSERT INTO kvstore_Sipsettings (\`key\`, \`val\`, \`type\`, \`id\`) VALUES ('rtpstart', '$RTP_PORT_START', NULL, 'noid') ON DUPLICATE KEY UPDATE val = '$RTP_PORT_START';
			INSERT INTO kvstore_Sipsettings (\`key\`, \`val\`, \`type\`, \`id\`) VALUES ('rtpend', '$RTP_PORT_END', NULL, 'noid') ON DUPLICATE KEY UPDATE val = '$RTP_PORT_END';
		EOF
	fi

	set -e
}

install()
{
	wait_for_connection 'database' $DB_HOST $DB_PORT

	[ -n "$DB_PASS" ] && PASS="-p$DB_PASS" || PASS=''

	configure

	cd /usr/src/freepbx
	./start_asterisk start

	set +e

	# get asterix manager password from settings in case we have already populated database
	AMPMGRPASS=$(echo 'SELECT value FROM freepbx_settings WHERE keyword = "AMPMGRPASS";' | mysql -u$DB_USER $PASS -h$DB_HOST -P$DB_PORT $DB_NAME -N 2>&1)
	if [ $? -eq 0 ]; then
		sed -i -e "s/\(\\\$amp_conf\['AMPMGRPASS'\] = \)md5(uniqid())/\1'$AMPMGRPASS'/" \
		./installlib/installcommand.class.php
		printf "Asterisk manager secret updated from DB.\n"
	fi

	# get list of modules which we would need to install if database was already populated
	MODULES=$(echo 'SELECT modulename FROM modules WHERE enabled = 1' | mysql -u$DB_USER $PASS -h$DB_HOST -P$DB_PORT $DB_NAME -N 2>/dev/null | tr '\n' ' ')

	set -e

	# not sure why install script doesn't save cdr db name to the config file and all time fallback to asteriskcdrdb during module installation
	sed -i \
	-e "s/\(\\\$amp_conf\['AMPDBHOST'\] = '\).*;/\1$DB_HOST';/" \
	-e "s/'@'localhost/'@'%/" \
	-e "s/\(\\\$amp_conf\['AMPDBENGINE'\] = '{\\\$amp_conf\['AMPDBENGINE'\]}';\)/\1\n\\\\\$amp_conf['CDRDBNAME'] = '$DB_NAME';/" \
	-e "s/\(fwconsole chown\) > \/dev\/tty/\1/" \
	./installlib/installcommand.class.php

	./install -n --dbuser=$DB_USER --dbpass=$DB_PASS --dbname=$DB_NAME --cdrdbname=$DB_NAME

	# fix issue with featurecode table for column "helptext"
	# echo 'ALTER TABLE `featurecodes` CHANGE `helptext` `helptext` VARCHAR(2000)' | mysql -u$DB_USER $PASS -h$DB_HOST -P$DB_PORT $DB_NAME

	configure

	# install modules
	set +e
	mysql -u$DB_USER $PASS -h$DB_HOST -P$DB_PORT $DB_NAME < ./installlib/SQL/cdr.sql 2>/dev/null
	set -e

	if [ -n "$MODULES" ]; then
		fwconsole ma install $MODULES
	else
		fwconsole ma install $FREEPBX_MODULES

		if [ -n "$EXTRA_MODULES" ]; then
			fwconsole ma install $EXTRA_MODULES
		fi
	fi

	configure

	fwconsole reload
	fwconsole stop
}

if [ ! -f "/etc/freepbx.conf" ]; then
	install
fi

case "$1" in
	start)
		sed -i \
		-e "s/%USERNAME%/$SUPERVISOR_USERNAME/" \
		-e "s/%PASSWORD%/$SUPERVISOR_PASSWORD/" \
		/etc/supervisor/supervisord.conf

		exec supervisord -c /etc/supervisor/supervisord.conf
		;;

	configure)
		configure
		;;

	install)
		install
		;;

	update)
		install update
		;;

	*)
		exec $@
esac