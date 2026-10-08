#!/bin/sh
# Builds MakeMKV for Linux from its two official packages (makemkv-oss: source, makemkv-bin: the
# makemkvcon program) into a folder of the user's – no administrator rights, nothing outside it.
#
#     build-makemkv-linux.sh <makemkv-oss-X.tar.gz> <makemkv-bin-X.tar.gz> <target folder> <log file>
#
# The last line of the output says what happened; exit 0 = built, 2 = build tools or libraries
# are missing (the line names the command that installs them), 1 = the build failed (see the log).
# Using makemkv-bin means accepting MakeMKV's licence (https://www.makemkv.com/eula); My AACS Plugin
# says so before it starts this script.
set -u
oss="$1"; bin="$2"; prefix="$3"; log="$4"

missing=""
for tool in gcc g++ make pkg-config tar; do
    command -v "$tool" > /dev/null 2>&1 || missing="$missing $tool"
done
if command -v pkg-config > /dev/null 2>&1; then
    for lib in openssl expat zlib libavcodec libavutil; do
        pkg-config --exists "$lib" 2> /dev/null || missing="$missing $lib"
    done
fi
if [ -n "$missing" ]; then
    if command -v dnf > /dev/null 2>&1; then
        hint="sudo dnf install gcc-c++ make pkgconf-pkg-config openssl-devel expat-devel zlib-devel ffmpeg-free-devel"
    elif command -v apt-get > /dev/null 2>&1; then
        hint="sudo apt install build-essential pkg-config libssl-dev libexpat1-dev zlib1g-dev libavcodec-dev"
    elif command -v pacman > /dev/null 2>&1; then
        hint="sudo pacman -S --needed base-devel openssl expat zlib ffmpeg"
    elif command -v zypper > /dev/null 2>&1; then
        hint="sudo zypper install gcc-c++ make pkg-config libopenssl-devel libexpat-devel zlib-devel ffmpeg-devel"
    else
        hint="a C++ compiler, make, pkg-config and the development files of OpenSSL, expat, zlib and FFmpeg"
    fi
    echo "these are missing:$missing. Install them with: $hint - then click the button again"
    exit 2
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
jobs="$(getconf _NPROCESSORS_ONLN 2> /dev/null || echo 2)"
{
    set -e
    tar -xzf "$oss" -C "$work"
    tar -xzf "$bin" -C "$work"
    cd "$work"/makemkv-oss-*
    # libmmbd starts makemkvcon from a fixed list of folders: add ours
    for f in libmakemkv/src/sys_linux.cpp libabi/src/sys_linux.cpp; do
        [ -f "$f" ] && sed -i "s|\"/usr/local/bin\",|\"/usr/local/bin\", \"$prefix/bin\",|" "$f"
    done
    ./configure --prefix="$prefix" --disable-gui
    make -j"$jobs"
    make install
    cd "$work"/makemkv-bin-*
    mkdir -p tmp
    echo accepted > tmp/eula_accepted
    make PREFIX="$prefix" install
} > "$log" 2>&1
rc=$?
if [ "$rc" != 0 ] || [ ! -x "$prefix/bin/makemkvcon" ]; then
    echo "the build failed, see $log"
    exit 1
fi
echo "built in $prefix"
exit 0
