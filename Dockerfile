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
	unixodbc cron $BUILD_DEPS

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

# download freepbx
ENV FREEPBX_VERSION=14.0
RUN set -ex; \
	cd /usr/src; \
	curl -sL http://mirror.freepbx.org/modules/packages/freepbx/freepbx-${FREEPBX_VERSION}-latest.tgz | tar xfz -

# cleanup dev dependencies
RUN set -ex; \
	apt-get purge -y ${BUILD_DEPS}; \
	apt-get autoremove -y; \
	rm -rf /var/lib/apt/lists/*; \
	rm -r /usr/src/asterisk-${ASTERIX_VERSION}

# create directories
RUN set -ex; \
	mkdir -p /certs

# ODBC configuration
RUN echo '[MariaDB]\n \
Description = ODBC for MariaDB\n \
Driver = /usr/lib/x86_64-linux-gnu/odbc/libmaodbc.so\n \
Setup = /usr/lib/x86_64-linux-gnu/odbc/libodbcmyS.so\n \
FileUsage = 1\n' > /etc/odbcinst.ini

# import GPG keys
RUN sudo -u asterisk gpg2 --no-tty --keyserver pool.sks-keyservers.net --recv-key 9F9169F4B33B4659; \
	sudo -u asterisk gpg2 --no-tty --keyserver pool.sks-keyservers.net --recv-key 86CE877469D2EAD9

# supervisord
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf

# add entrypoint
COPY ./entrypoint.sh /
RUN chmod +x /entrypoint.sh && ln -s /entrypoint.sh /bin/run
ENTRYPOINT ["/entrypoint.sh"]

EXPOSE 80 443 5060 5160 8001 8003 8008 8009 10000-20000/udp

# default variables
ENV DB_HOST=db \
	DB_PORT=3306 \
	DB_USERNAME=root \
	DB_PASSWORD= \
	DB_NAME=freepbx \
	SSL=0 \
	RTP_PORT_START=10000 \
	RTP_PORT_END=20000

CMD ["start"]