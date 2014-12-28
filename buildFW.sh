#!/usr/bin/env bash
#
# buildFW.sh
#
# Update & Make  -   Update source code and make the build
BASEDIR=$(dirname $(readlink -f $0))

### Target definitions
TARGET=trunk
OUT=repository

cd $BASEDIR

usage() {
	cat <<EOF
Usage: $0 <command> [arguments]
Commands:
	help					This help text
	build all				Build all enviromets 
	build <name>			Build specified enviroment
	profile new <name>		Add a new profile
	profile remove <name>	Remove a new profile
	download				Download a setup the toolchain

EOF
	exit ${1:-1}
}

error() {
	echo "$0: $*"
	exit 1
}

env_write_version(){
	local OwVers=`grep RELEASE: include/toplevel.mk | cut -d "=" -f 2`
	local REV=r`git log | grep -m 1 git-svn-id | awk '{ gsub(/.*@/, "", $0); print r$1 }'`

	echo "Build Date: "`date "+%F %H:%M"` >> files/etc/build
	echo "Openwrt:   "$OwVers $REV >> files/etc/build
	echo "luci:      "`(cd feeds/luci && git show --format="%ai %h %s" | head -n 1 | cut -b1-60)` >> files/etc/build
	echo "packages:  "`(cd feeds/packages && git show --format="%ai %h %s" | head -n 1 | cut -b1-60)` >> files/etc/build
	echo "routing:   "`(cd feeds/routing && git show --format="%ai %h %s" | head -n 1 | cut -b1-60)` >> files/etc/build
}

env_repository_current() {
	local BOARD=`grep TARGET_BOARD .config | cut -f 2 -d \"`
	local REV=r`git log | grep -m 1 git-svn-id | awk '{ gsub(/.*@/, "", $0); print r$1 }'`
	cat > package/system/opkg/files/opkg.conf <<EOF
dest root /
dest ram /tmp
lists_dir ext /var/opkg-lists
option overlay_root /overlay
src/gz hitech_base http://openwrt.kytech.it/repository/$REV/$BOARD/packages/base
src/gz hitech_luci http://openwrt.kytech.it/repository/$REV/$BOARD/packages/luci
src/gz hitech_packages http://openwrt.kytech.it/repository/$REV/$BOARD/packages/packages
src/gz hitech_routing http://openwrt.kytech.it/repository/$REV/$BOARD/packages/routing
EOF
}



env_build() {
	local NAME="$1"
	[ -z "$NAME" ] && usage
	
	cd $TARGET
	
	if [ "$NAME" == "all" ]; then
		echo "Building all env"
		echo "Missing Functions"
	else		
		$BASEDIR/$TARGET/scripts/env save
		$BASEDIR/$TARGET/scripts/env switch $NAME
		if [ "$?" = "0" ]; then		
			echo "Building $NAME env"
			env_prepare_current
			env_build_current
			env_deploy_current
			env_clean_current			
			cd $BASEDIR
			echo "Done."
		else
			error "environment '$NAME' not found"
		fi
	fi

}

env_prepare_current() {
	echo "...update main source..."
	git pull origin

	echo "...update feeds..."
	$BASEDIR/$TARGET/scripts/feeds update -a

	echo "...Patching source for current env..."
	patch -p1 -i "$BASEDIR/$TARGET/env/trunk-openwrt.patch"

	echo "...install feeds..."
	$BASEDIR/$TARGET/scripts/feeds install -a

	echo "...moving config..."
	cp "$BASEDIR/$TARGET/.config.init" "$BASEDIR/$TARGET/.config"

	echo "...make defconfig..."
	make defconfig

	echo "...download all new source packages..."
	make download

	echo "...create version info file..."
	env_write_version

	echo "...patching repository..."
	cp "$BASEDIR/$TARGET/package/system/opkg/files/opkg.conf" "$BASEDIR/$TARGET/package/system/opkg/files/opkg.conf.original"
	env_repository_current
}

env_deploy_current() {
	echo "...deploying images..."
	local RDIR=$BASEDIR/$TARGET/bin/`grep TARGET_BOARD .config | cut -f 2 -d \"`
	local REV=r`git log | grep -m 1 git-svn-id | awk '{ gsub(/.*@/, "", $0); print r$1 }'`
	mkdir -p "$BASEDIR/$OUT/$REV/"
	mv "$RDIR $BASEDIR/$OUT/$REV/"
}

env_clean_current() {
	echo "...restoring patched files..."	
	#cleaning current target patch
	patch -p1 -Ri "$BASEDIR/$TARGET/env/trunk-openwrt.patch"
	
	#cleaning files directory
	rm -R "$BASEDIR/$TARGET/env/files/"
	
	#restore original repo
	rm "$BASEDIR/$TARGET/package/system/opkg/files/opkg.conf"	
	mv "$BASEDIR/$TARGET/package/system/opkg/files/opkg.conf.original" "package/system/opkg/files/opkg.conf"
}

env_build_current() {	
	echo "...clean and make ..."
	nice -n 17 ionice -c 3 -n 7 rm -rf bin tmp build_dir/target-* staging_dir/target-*
	nice -n 17 ionice -c 3 -n 7 make -j 5 V=s 2>&1 | tee build.log | grep -i -E "^make.*(error|[12345]...Entering dir)"	
}

env_download() {
	### main directory
	cd "$BASEDIR"
	git clone git://git.openwrt.org/openwrt.git $TARGET
	cd "$TARGET"

	mkdir files

	echo "Patching Base Files..."
	### patch sources (main Openwrt, luci,packages,routing feeds)
	### patch main Openwrt first to set feeds correctly, then update the feeds
	patch -p1 -i "$BASEDIR/trunk-openwrt.patch"

	echo "Updating Feeds..."

	$BASEDIR/$TARGET/scripts/feeds update -a

	echo "Patching Feeds Files..."
	cd "$BASEDIR/$TARGET/feeds/luci"
	patch -p1 -i "$BASEDIR/trunk-luci.patch"
	cd "$BASEDIR/$TARGET/feeds/packages"
	patch -p1 -i "$BASEDIR/trunk-packages.patch"
	cd "$BASEDIR/$TARGET/feeds/routing"
	patch -p1 -i "$BASEDIR/trunk-routing.patch"

	echo "Installing Feeds..."
	$BASEDIR/$TARGET/scripts/feeds install -a

	### step 7: add files created by the patches to svn and git
	echo "Synk Patched files with GIT..."
	cd "$BASEDIR/$TARGET"
	#git add files
	#git add .config.init
	(cd "$BASEDIR/$TARGET/feeds/luci"; git add -A)
	(cd "$BASEDIR/$TARGET/feeds/packages"; git add -A)
	(cd "$BASEDIR/$TARGET/feeds/routing"; git add -A)

	echo "Done."
}

env_profiles() {
	local COMMAND="$1"
	local NAME="$2"
	[ -z "$COMMAND" ] && usage
	
	cd "$BASEDIR/$TARGET"
	
	if [ "$COMMAND" == "new" ]; then
		echo "Adding profiles..."
		env_profiles_add $NAME
	elif [ "$COMMAND" == "remove" ]; then
		echo "Removing profiles..."
		env_profiles_remove $NAME	
	else
		usage
		error "$COMMAND is not a valid option!"		
	fi
	cd "$BASEDIR"
}

env_profiles_add() {
	local NAME="$1"
	[ -z "$NAME" ] && usage
	if [ -d "$BASEDIR/profiles/$NAME" ]; then
		#Create the environment
		$BASEDIR/$TARGET/scripts/env new $NAME		
		if [ "$?" = "0" ]; then		
			#copy patchs
			cp "$BASEDIR/profiles/$NAME/"* "$BASEDIR/$TARGET/env/"	
			$BASEDIR/$TARGET/scripts/env save		
			echo "Done."
		else
			error "Something went wrong!"
		fi
	else
		error "Missing $NAME profile!"
	fi	
}

env_profiles_remove() {
	local NAME="$1"
	[ -z "$NAME" ] && usage
	$BASEDIR/$TARGET/scripts/env switch master
	$BASEDIR/$TARGET/scripts/env delete $NAME
	if [ "$?" = "0" ]; then
		echo "Done."
	else
		error "Something went wrong!"
	fi
}

COMMAND="$1"; shift
case "$COMMAND" in
	help) usage 0;;
	download) env_download 0;;
	profile) env_profiles "$@";;
	build) env_build "$@";;
	*) usage;;
esac
