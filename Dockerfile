FROM debian:stretch-slim

RUN apt-get update -y && apt-get upgrade -y

# asterisk user
RUN useradd -mU asterisk

ENV BUILD_DEPS='build-essential linux-headers-amd64 libncurses5-dev libssl-dev libmariadbclient-dev \
	libxml2-dev libnewt-dev libsqlite3-dev libasound2-dev pkg-config automake libtool autoconf unixodbc-dev \
	uuid-dev libogg-dev libvorbis-dev libicu-dev libcurl4-openssl-dev libical-dev libneon27-dev libsrtp0-dev \
	libspandsp-dev python-dev libtool-bin libresample1-dev libedit-dev'

# install dependencies
RUN apt-get install --no-install-recommends -y apache2 mysql-client bison flex curl sox mpg123 ffmpeg sqlite3 \
	uuid sudo subversion apt-transport-https lsb-release ca-certificates netcat supervisor gnupg2 net-tools dirmngr \
	unixodbc cron git $BUILD_DEPS

# PHP 5.6
RUN set -ex; \
	curl -so /etc/apt/trusted.gpg.d/php.gpg https://packages.sury.xyz/php/apt.gpg; \
	echo "deb https://packages.sury.xyz/php/ $(lsb_release -sc) main" > /etc/apt/sources.list.d/php.list; \
	apt-get update -y && apt-get upgrade -y; \
	apt-get install -y php5.6 php5.6-curl php5.6-cli php5.6-mysql php5.6-gd php5.6-xml php5.6-mbstring php-pear

# nodejs
RUN curl -sL https://deb.nodesource.com/setup_8.x | sudo -E bash -
RUN sudo apt-get install -y nodejs

# MariaDB ODBC connector
RUN curl -s https://downloads.mariadb.com/Connectors/odbc/connector-odbc-2.0.18/mariadb-connector-odbc-2.0.18-ga-debian-x86_64.tar.gz | tar xfz - -C /usr/lib/x86_64-linux-gnu/odbc --strip-components=1 lib/libmaodbc.so; \
	chown root:root /usr/lib/x86_64-linux-gnu/odbc/libmaodbc.so

# install asterisk
ENV ASTERISK_VERSION=15.7.0
RUN set -ex; \
	cd /usr/src; \
	curl -sL http://downloads.asterisk.org/pub/telephony/asterisk/releases/asterisk-${ASTERISK_VERSION}.tar.gz | tar xfz -; \
	cd /usr/src/asterisk-${ASTERISK_VERSION}; \
	make distclean; \
	./configure --with-pjproject-bundled --with-jansson-bundled --with-ssl=ssl --with-srtp --with-resample; \
	contrib/scripts/get_mp3_source.sh; \
	make menuselect/menuselect menuselect-tree menuselect.makeopts; \
	menuselect/menuselect --disable BUILD_NATIVE --enable format_mp3 --enable app_fax; \
	make install; \
	ldconfig


RUN set -ex; \
	a2enmod rewrite; \
	chown asterisk:asterisk /var/run/asterisk; \
	chown -R asterisk:asterisk /etc/asterisk; \
	chown -R asterisk:asterisk /var/lib/asterisk; \
	chown -R asterisk:asterisk /var/log/asterisk; \
	chown -R asterisk:asterisk /var/spool/asterisk; \
	rm -rf /var/www/html; \
	sed -i -e 's/\(^upload_max_filesize = \).*/\120M/' -e 's/\(memory_limit = \)128M/\1256M/' /etc/php/5.6/apache2/php.ini; \
	sed -i -e 's/^\(User\|Group\).*/\1 asterisk/' -e 's/AllowOverride None/AllowOverride All/' /etc/apache2/apache2.conf

# download freepbx and add modules, you can specify module version after the slash or left it blank to use global version
ENV FREEPBX_VERSION=14.0 \
	FREEPBX_MODULES='callrecording conferences customappsreg featurecodeadmin logfiles recordings voicemail cdr \
	core dashboard infoservices music sipsettings soundlang'

# download freepbx modules
ENV FREEPBX_DOWNLOAD_MODULES="$FREEPBX_MODULES amd announcement arimanager asterisk-cli asteriskinfo backup blacklist \
	bulkhandler calendar callback	callforward callwaiting cel certman cidlookup configedit contactmanager manager \
	daynight dictate directory disa donotdisturb fax findmefollow hotelwakeup iaxsettings ivr languages miscapps \
	miscdests outroutemsg paging parking pbdirectory phonebook pinsets pm2 presencestate printextensions queueprio \
	queues restapi ringgroups setcid speeddial superfecta timeconditions tts ttsengines ucp userman vmblast \
	weakpasswords webrtc"

COPY modown.php /usr/bin
RUN chmod +x /usr/bin/modown.php && ln -s /usr/bin/modown.php /usr/bin/modown

RUN set -ex; \
	cd /usr/src; \
	modown all $FREEPBX_VERSION ./ framework; \
	mv framework freepbx; \
	mkdir -p /var/www/html/admin/modules; \
	modown all $FREEPBX_VERSION /var/www/html/admin/modules $FREEPBX_DOWNLOAD_MODULES


# add common sound packages for module soundlang so we will not need to download it during runtime
ENV FREEPBX_SOUND_PACKAGES='asterisk/core-sounds/en/ulaw asterisk/core-sounds/en/g722 asterisk/extra-sounds/en/ulaw asterisk/extra-sounds/en/g722'
RUN set -ex; \
	modown sounds $FREEPBX_VERSION /var/lib/asterisk/sounds $FREEPBX_SOUND_PACKAGES; \
	chown -R asterisk:asterisk /var/lib/asterisk

# install dependencies for ucp and pm2
RUN set -ex; \
	cd /var/www/html/admin/modules/ucp/node; \
	npm install; \
	cd /var/www/html/admin/modules/pm2/node; \
	npm install; \
	chown -R asterisk:asterisk /var/www/html/admin/modules

# cleanup dev dependencies
#RUN set -ex; \
#	apt-get purge -y ${BUILD_DEPS}; \
#	apt-get autoremove -y; \
#	rm -rf /var/lib/apt/lists/*; \
#	rm -r /usr/src/asterisk-${ASTERIX_VERSION}

# ODBC configuration
RUN echo '[MariaDB]\n \
Description = ODBC for MariaDB\n \
Driver = /usr/lib/x86_64-linux-gnu/odbc/libmaodbc.so\n \
Setup = /usr/lib/x86_64-linux-gnu/odbc/libodbcmyS.so\n \
FileUsage = 1\n' > /etc/odbcinst.ini

# import GPG keys - use local files as sometimes we have building issues to download them from pgp servers
RUN sudo -u asterisk gpg --no-tty --import /usr/src/freepbx/amp_conf/htdocs/admin/libraries/BMO/*.key

# supervisord
ENV SUPERVISOR_USERNAME=admin \
	SUPERVISOR_PASSWORD=
COPY supervisor /etc/supervisor

# add tini and entrypoint
ENV TINI_VERSION v0.18.0
ADD https://github.com/krallin/tini/releases/download/${TINI_VERSION}/tini /sbin/tini
COPY ./entrypoint.sh /
RUN chmod +x /entrypoint.sh && ln -s /entrypoint.sh /bin/run; \
	chmod +x /sbin/tini
ENTRYPOINT ["/sbin/tini", "--", "/entrypoint.sh"]

EXPOSE 80 443 5060 5061 5160 5161 9001 10000-20000/udp

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