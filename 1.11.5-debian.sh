#!/bin/bash
set -u
if [ "$(id -u)" -eq 0 ]; then echo -e "This script is not intended to be run as root.\nExiting." && exit 1; fi


## Note to self. (For use when generating patches).
# diff -ur nginx-1.11.5/ nginx-1.11.5-patched/ > ../boring.patch


NGXVER="1.11.5" # Target nginx version
BDIR="/tmp/boringnginx-$RANDOM" # Set build directory


# Handle arguments passed to the script. Currently only accepts the flag to
# include passenger at compile time,but I might add a help section or more options soon.
PASSENGER=0
while [ "$#" -gt 0 ]; do
	case $1 in
		--passenger|-passenger|passenger) PASSENGER="1"; shift 1;;
		*) echo "Invalid argument: $1" && exit 10;;
	esac
done


# Prompt our user before we start removing stuff
CONFIRMED=0
echo -e "This script will remove any versions of Nginx you installed using apt, and\nreplace any version of Nginx built with a previous version of this script."
while true
do
	echo ""
	read -p "Do you wish to continue? (Y/N)" answer
	case $answer in
		[yY]* )
			CONFIRMED=1
			break;;

		* )
			echo "Please enter 'Y' to continue or use ^C to exit.";;
	esac
done
if [ "$CONFIRMED" -eq 0 ]; then echo -e "Something went wrong.\nExiting." && exit 1; fi


# Install deps & remove old nginx if we installed it with apt
sudo systemctl stop nginx
sudo systemctl disable nginx
sudo apt remove nginx nginx-common nginx-full nginx-light
sudo apt install build-essential cmake git gnupg golang libpcre3-dev wget zlib1g-dev libcurl4-openssl-dev


# Build BoringSSL
git clone https://boringssl.googlesource.com/boringssl "$BDIR/boringssl"
cd "$BDIR/boringssl"
mkdir build && cd build
cmake ../
make


# Make an .openssl directory for nginx and then symlink BoringSSL's include directory tree
mkdir -p "$BDIR/boringssl/.openssl/lib"
cd "$BDIR/boringssl/.openssl"
ln -s ../include


# Copy the BoringSSL crypto libraries to .openssl/lib so nginx can find them
cd "$BDIR/boringssl"
cp "build/crypto/libcrypto.a" "build/ssl/libssl.a" ".openssl/lib"


# Download "ngx_headers_more" module for finer-grained control over server headers
git clone https://github.com/openresty/headers-more-nginx-module.git "$BDIR/ngx_headers_more"


# Import all nginx PGP keys
cd "$BDIR"
wget --https-only "https://nginx.org/keys/aalexeev.key" && gpg --import "aalexeev.key"
wget --https-only "https://nginx.org/keys/is.key" && gpg --import "is.key"
wget --https-only "https://nginx.org/keys/mdounin.key" && gpg --import "mdounin.key"
wget --https-only "https://nginx.org/keys/maxim.key" && gpg --import "maxim.key"
wget --https-only "https://nginx.org/keys/sb.key" && gpg --import "sb.key"
wget --https-only "https://nginx.org/keys/nginx_signing.key" && gpg --import "nginx_signing.key"


# Verify and extract nginx sources
cp -f -v "$SCRIPTDIR/sources/nginx-$NGXVER.tar.gz" "$BDIR/nginx-$NGXVER.tar.gz"
cp -f -v "$SCRIPTDIR/patches/$NGXVER.patch" "$BDIR/$NGXVER.patch"
if [ ! -f "nginx-$NGXVER.tar.gz" ]; then echo -e "\nFailed to find nginx $NGXVER sources!" && exit 2; fi

verify_sig() {
# This function takes a filename as an argument, and verifies the GPG sig of it.
# If the file passes, it returns an error code of 0 that we can rely on later in the main script.
# If it fails, it returns an error code of 1
	local file=$1
	out=$(gpg --status-fd 1 --verify "$file" 2>/dev/null)
	if  echo "$out" | grep -qs "\[GNUPG:\] GOODSIG" && echo "$out" | grep -qs "\[GNUPG:\] VALIDSIG"
	then
		return 0
	else
		echo "$out" >&2
		return 1
	fi
}

wget --https-only "https://nginx.org/download/nginx-$NGXVER.tar.gz.asc" # Download sig file for this source code tarball
if verify_sig "nginx-$NGXVER.tar.gz.asc" # Verify that our source tarball has been signed with the key from the nginx site
then
	echo "Good signature on source file."
else
	echo "GPG VERIFICATION OF SOURCE CODE FAILED!"
	echo "EXITING!"
	exit 100
fi


# Since we've got this far, it means verification was successful so we can unpack the sources and start working on them
tar zxvf "nginx-$NGXVER.tar.gz"
cd "$BDIR/nginx-$NGXVER"


# Config nginx based on the flags passed to the script, if any
EXTRACONFIG=""
WITHROOT=""
if [ $PASSENGER -eq 1 ]
then
	echo "" && echo "Phusion Passenger module enabled."
	sudo gem install rails
	sudo gem install passenger
	EXTRACONFIG="$EXTRACONFIG --add-module=$(passenger-config --root)/src/nginx_module"
	WITHROOT="sudo " # Passenger needs root to read/write to /var/lib/gems
fi


# Run the config with default options and append any additional options specified by the above section
$WITHROOT./configure --prefix=/usr/share/nginx \
	--sbin-path=/usr/sbin/nginx \
	--conf-path=/etc/nginx/nginx.conf \
	--error-log-path=/var/log/nginx/error.log \
	--http-log-path=/var/log/nginx/access.log \
        --pid-path=/run/nginx.pid \
        --lock-path=/run/lock/subsys/nginx \
        --user=www-data \
        --group=www-data \
        --with-threads \
        --with-file-aio \
        --with-http_ssl_module \
        --with-http_v2_module \
        --with-http_realip_module \
        --with-http_gunzip_module \
        --with-http_gzip_static_module \
        --with-http_slice_module \
        --with-http_stub_status_module \
        --without-select_module \
        --without-poll_module \
        --without-mail_pop3_module \
        --without-mail_imap_module \
        --without-mail_smtp_module \
	--add-module="$BDIR/ngx_headers_more" \
	--with-openssl="$BDIR/boringssl" \
	--with-cc-opt="-g -O2 -fPIE -fstack-protector-all -D_FORTIFY_SOURCE=2 -Wformat -Werror=format-security -I ../boringssl/.openssl/include/" \
	--with-ld-opt="-Wl,-Bsymbolic-functions -Wl,-z,relro -L ../boringssl/.openssl/lib" \
	$EXTRACONFIG


# Fix "Error 127" during build
touch "$BDIR/boringssl/.openssl/include/openssl/ssl.h"


# Fix some other build errors caused by nginx expecting OpenSSL
patch -p1 < "../patches/$NGXVER.patch"


# Build nginx
make # Fortunately we can get away without root here, even for Passenger installs
sudo make install


# Add systemd service
cd "$BDIR/"
wget "https://github.com/ajhaydock/BoringNginx/raw/master/nginx.service"
sudo cp -f -v nginx.service "/lib/systemd/system/nginx.service"

# Enable & start service
sudo systemctl enable nginx.service
sudo systemctl start nginx.service

# Finish script
echo ""
sudo /usr/sbin/nginx -V
echo ""
sudo ldd /usr/sbin/nginx

# If you previously installed nginx via apt and get errors when trying to boot this compiled version, you might need to remove /etc/nginx and then try the buildscript again (or just the 'make install' part)
