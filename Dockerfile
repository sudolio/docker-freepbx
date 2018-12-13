FROM debian:stretch-slim

RUN apt-get update -y && apt-get upgrade -y

# asterisk user
RUN useradd -mU asterisk

ENV BUILD_DEPS='build-essential linux-headers-amd64 libncurses5-dev libssl-dev libmariadbclient-dev \
	libxml2-dev libnewt-dev libsqlite3-dev libasound2-dev pkg-config automake libtool autoconf unixodbc-dev \
	uuid-dev libogg-dev libvorbis-dev libicu-dev libcurl4-openssl-dev libical-dev libneon27-dev libsrtp0-dev \
	libspandsp-dev python-dev libtool-bin libresample1-dev'

# install dependencies
RUN apt-get install --no-install-recommends -y apache2 mysql-client bison flex curl sox mpg123 ffmpeg sqlite3 \
	uuid sudo subversion apt-transport-https lsb-release ca-certificates netcat supervisor gnupg2 net-tools dirmngr \
	unixodbc cron git $BUILD_DEPS

# PHP 5.6
RUN set -ex; \
	curl -so /etc/apt/trusted.gpg.d/php.gpg https://packages.sury.xyz/php/apt.gpg; \
	echo "deb https://packages.sury.xyz/php/ $(lsb_release -sc) main" > /etc/apt/sources.list.d/php.list; \
	apt-get update -y; \
	apt-get install -y php5.6 php5.6-curl php5.6-cli php5.6-mysql php5.6-gd php5.6-xml php5.6-mbstring php-pear

# nodejs
RUN curl -sL https://deb.nodesource.com/setup_8.x | sudo -E bash -
RUN sudo apt-get install -y nodejs

# MariaDB ODBC connector
RUN curl -s https://downloads.mariadb.com/Connectors/odbc/connector-odbc-2.0.18/mariadb-connector-odbc-2.0.18-ga-debian-x86_64.tar.gz | tar xfz - -C /usr/lib/x86_64-linux-gnu/odbc --strip-components=1 lib/libmaodbc.so; \
	chown root:root /usr/lib/x86_64-linux-gnu/odbc/libmaodbc.so

# install asterisk
ENV ASTERIX_VERSION=15.6.2
RUN set -ex; \
	cd /usr/src; \
	curl -sL http://downloads.asterisk.org/pub/telephony/asterisk/asterisk-${ASTERIX_VERSION}.tar.gz | tar xfz -; \
	cd /usr/src/asterisk-${ASTERIX_VERSION}; \
	./configure --with-pjproject-bundled --with-jansson-bundled --with-ssl --with-srtp --with-resample; \
	contrib/scripts/get_mp3_source.sh; \
	make menuselect/menuselect menuselect-tree menuselect.makeopts; \
	menuselect/menuselect --disable BUILD_NATIVE --enable format_mp3 --enable app_fax; \
	make install; \
	ldconfig

RUN set -ex; \
	a2enmod rewrite; \
	chown asterisk. /var/run/asterisk; \
	chown -R asterisk. /etc/asterisk; \
	chown -R asterisk. /var/lib/asterisk; \
	chown -R asterisk. /var/log/asterisk; \
	chown -R asterisk. /var/spool/asterisk; \
	rm -rf /var/www/html; \
	sed -i -e 's/\(^upload_max_filesize = \).*/\120M/' -e 's/\(memory_limit = \)128M/\1256M/' /etc/php/5.6/apache2/php.ini; \
	sed -i -e 's/^\(User\|Group\).*/\1 asterisk/' -e 's/AllowOverride None/AllowOverride All/' /etc/apache2/apache2.conf

# download freepbx and add modules, you can specify module version after the slash or left it blank to use global version
ENV FREEPBX_VERSION=14.0 \
	FREEPBX_MODULES='callrecording conferences customappsreg featurecodeadmin logfiles recordings voicemail cdr \
	core dashboard infoservices music sipsettings soundlang' \
	FREEPBX_DOWNLOAD_MODULES="$FREEPBX_MODULES amd announcement arimanager asterisk-cli asteriskinfo backup blacklist \
	bulkhandler calendar callback	callforward callwaiting cel certman cidlookup configedit contactmanager manager \
	daynight dictate directory disa donotdisturb fax findmefollow hotelwakeup iaxsettings ivr languages miscapps \
	miscdests outroutemsg paging parking pbdirectory phonebook pinsets pm2 presencestate printextensions queueprio \
	queues restapi ringgroups setcid speeddial superfecta timeconditions tts ttsengines ucp userman vmblast \
	weakpasswords webrtc"

# download freepbx modules
COPY modown.php /usr/src/modown/
RUN set -ex; \
	cd /usr/src/modown; \
	php modown.php $FREEPBX_VERSION "framework $FREEPBX_DOWNLOAD_MODULES"; \
	mkdir /usr/src/freepbx; \
	tar xfz ./framework.tgz -C /usr/src/freepbx --strip-components=1

RUN set -x; \
	mkdir -p /var/www/html/admin/modules; \
	for i in $FREEPBX_DOWNLOAD_MODULES; do \
		tar xfz /usr/src/modown/$i.tgz -C /var/www/html/admin/modules; \
	done


# add common sound packages for module soundlang so we will not need to install it during runtime
ENV FREEPBX_SOUND_PACKAGES='core-sounds/ulaw core-sounds/g722 extra-sounds/ulaw extra-sounds/g722'
RUN set -ex; \
	cd /var/lib/asterisk/sounds/en; \
	for i in $FREEPBX_SOUND_PACKAGES; do \
		curl -sL http://downloads.asterisk.org/pub/telephony/sounds/asterisk-${i%/*}-en-${i#*/}-current.tar.gz | tar xfz -; \
	done; \
	chown -R asterisk. /var/lib/asterisk

# install dependencies for ucp and pm2 module
#RUN set -ex; \
#	cd /usr/src/freepbx/amp_conf/htdocs/admin/modules/ucp/node; \
#	npm install; \
#	cd /usr/src/freepbx/amp_conf/htdocs/admin/modules/pm2/node; \
#	npm install


# cleanup dev dependencies
#RUN set -ex; \
#	apt-get purge -y ${BUILD_DEPS}; \
#	apt-get autoremove -y; \
#	rm -rf /var/lib/apt/lists/*; \
#	rm -r /usr/src/asterisk-${ASTERIX_VERSION}

# create directories
RUN set -ex; \
	mkdir -p /certs

# ODBC configuration
RUN echo '[MariaDB]\n \
Description = ODBC for MariaDB\n \
Driver = /usr/lib/x86_64-linux-gnu/odbc/libmaodbc.so\n \
Setup = /usr/lib/x86_64-linux-gnu/odbc/libodbcmyS.so\n \
FileUsage = 1\n' > /etc/odbcinst.ini

# import GPG keys - use local files as sometimes we have building issues to download them from pgp servers
#COPY ./pgp /pgp
#RUN sudo -u asterisk gpg --no-tty --import /pgp/freepbx_security.txt; \
#	sudo -u asterisk gpg --no-tty --import /pgp/freepbx_module_signing.txt
RUN sudo -u asterisk gpg --no-tty --import /usr/src/freepbx/amp_conf/htdocs/admin/libraries/BMO/*.key

# supervisord
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf

# add entrypoint
COPY ./entrypoint.sh /
RUN chmod +x /entrypoint.sh && ln -s /entrypoint.sh /bin/run
ENTRYPOINT ["/entrypoint.sh"]

EXPOSE 80 443 5060 5160 10000-20000/udp

# default variables
ENV DB_HOST=db \
	DB_PORT=3306 \
	DB_USERNAME=root \
	DB_PASSWORD= \
	DB_NAME=freepbx \
	SSL=0 \
	RTP_PORT_START=10000 \
	RTP_PORT_END=20000 \
	EXTRA_MODULES=''

CMD ["start"]