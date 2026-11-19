#!/bin/bash
#
# NAME:
# 	docker-build-appimage.sh -- build AppImage in docker container
#
# SYNOPSIS:
# 	docker run -rm \
# 	  -v "${PROJECT_DIR}:/workspace/src" \
# 	  -w "/workspace/src" \
# 	  "${DOCKER_IMAGE}" \
# 	  bash -c "build/docker-build-appimage.sh"

# wjg: Fail on unhandled errors even in pipelines and unset variables:
#	Don't change that because ignoring errors makes this less resilient
#	and much harder to debug!
set -euo pipefail

# Useful messaging functions
dbg() { [ "${DEBUG:-no}" = no ] || echo "$@" >&2; }
msg() { echo "$@" >&2; }
ok()  { echo "✅ $@" >&2; }
inf() { echo "ℹ️  $@" >&2; }
wrn() { echo "⚠️  WARNING: $@" >&2; }
err() { echo "❌ ERROR:   $@" >&2; }
fat() { echo "💀 FATAL:   $@" >&2; exit 1; }

# Set up variables for comprehensive AppImage creation
SRC="/workspace/src"
BUILD_DIR="${SRC}/build" 
APPIMAGE_DIR="${BUILD_DIR}/appimage"
APPDIR="${APPIMAGE_DIR}/AppDir"
DESKTOP_OUT="${APPDIR}/openterfaceqt.desktop"
APPIMAGE_OUT="${BUILD_DIR}"
OPENTERFACE_BUILD_STATIC=${OPENTERFACE_BUILD_STATIC:-OFF}

# Some sanity checks:
#	Do workspace and build directories exist?
[ -d "$SRC" ] || fat "workspace not found! Are you running in docker?"
[ -d "$BUILD_DIR" ] || fat "build not found! Have you run the docker build?"

# FIXME: Is the additional APPIMAGE_ARCH necessary?
# 	Reason: This must run in a container of the appropriate ARCH, so
# 		APPIMAGE_ARCH === ARCH?!?
ARCH=$(uname -m)
case $ARCH in
aarch64|arm64)	APPIMAGE_ARCH=aarch64;;
x86_64|amd64)	APPIMAGE_ARCH=x86_64;;
*)		APPIMAGE_ARCH=$ARCH;;
esac

# Determine version from resources/version.h
if [ -r "$SRC/resources/version.h" ]
then
	VERSION=$(sed <"$SRC/resources/version.h" -ne 's/.* APP_VERSION "\([^"]*\).*/\1/p')
else
	VERSION=unknown
fi

# Enhanced AppImage build script with comprehensive GStreamer plugin support
#	This script builds an AppImage with all necessary GStreamer plugins
#	for video capture.
msg "Building gstreamer enhanced Openterface AppImage version: ${VERSION}"

# Generic library copying function
#	copy_libraries "lpattern" ERROR|WARNING|FATAL tgt_dir [search_dir ...]
# Modified to generate much less noise, so warnings and errors become visible.
copy_libraries() {
    local lpattern="$1"
    local severity="$2"  # ERROR or WARNING or FATAL
    local tgtdir="$3"
    shift 3
    local sdirs=("$@")
    
    dbg "Searching for $lpattern libraries..."
    local found=0
    
    for search_dir in "${sdirs[@]}"
    do
        dbg "Checking: $search_dir"
        if [ -d "$search_dir" ]; then
            if ls "$search_dir"/${lpattern}* >/dev/null 2>&1; then
		found=1
                dbg "Found $lpattern in $search_dir"
                local files=$(ls -la "$search_dir"/${lpattern}* 2>/dev/null)
		dbg $(echo "$files" | sed 's/^/     /')
                # Copy both actual files AND symlinks to preserve
		# library versioning chains!
		[ "${DEBUG:-no}" != no ] && opts=avP || opts=aP
		failed=0
		for file in $(find "$search_dir" -maxdepth 1 -name "${lpattern}*" \( -type f -o -type l \) -print)
	        do
			msg=$(cp -$opts "$file" "$tgtdir/" 2>&1) || failed=1
			dbg "$msg"
		done
		if [ $failed = 0 ]
		then
			ok "$lpattern libraries copied to $tgtdir"
		elif [ $severity != FATAL ]
		then
			err "$lpattern libraries NOT copied to $tgtdir"
		else
			fat "$lpattern libraries NOT copied to $tgtdir"
		fi
                break
	    fi
        fi
    done
    
    if [ $found -eq 0 ]
    then
	    case $severity in
	    WARNING)	wrn "$lpattern libraries not found.";;
	    ERROR)	err "$lpattern libraries not found!";;
	    FATAL)	fat "$lpattern libraries not found!";;
	    esac
    fi
}

# Detect GStreamer plugins in container
# 	Uses first directory found - sequence matters!
GSTREAMER_HOST_DIR=""
for dir in \
	"/opt/gstreamer/lib/${ARCH}-linux-gnu/gstreamer-1.0" \
	"/opt/gstreamer/lib/${ARCH}-linux-gnu/" \
	"/usr/lib/${ARCH}-linux-gnu/gstreamer-1.0" \
	"/usr/lib/gstreamer-1.0"
do
	if [ -d "$dir" ]
	then
		GSTREAMER_HOST_DIR="$dir"
		ok "Found gstreamer plugin directory: $GSTREAMER_HOST_DIR"
		break
	fi
done

# Sanity check:
[ -n "$GSTREAMER_HOST_DIR" ] ||
	fat "gstreamer plugins not found. Install them and re-run build!"
[ -f "$GSTREAMER_HOST_DIR/libgstvideo4linux2.so" ] ||
	fat "gstreamer V4L2 plugin not found. Install it and re-run build!"

# NOTE: Previous code had logic to install gstreamer plugins here, which
#	is too late and could cause inconsistencies.
#	Use apt to install:
#		gstreamer1.0-plugins-base
#		gstreamer1.0-plugins-good
#		gstreamer1.0-plugins-bad
#	then re-run the build.

# Create comprehensive AppDir structure for the final AppImage
rm -rf "${APPDIR}"
mkdir -p "${APPDIR}/usr/bin" \
	"${APPDIR}/usr/share/applications" \
	"${APPDIR}/usr/share/icons/hicolor/128x128/apps" \
	"${APPDIR}/usr/share/icons/hicolor/256x256/apps" \
	"${APPDIR}/usr/share/metainfo" \
	"${APPDIR}/usr/share/openterfaceQT/translations" \
	"${APPDIR}/usr/share/pixmaps" \
	"${APPDIR}/usr/libexec/gstreamer-1.0" \
	"${APPDIR}/usr/lib/gstreamer-1.0" \
	"${APPDIR}/usr/lib/openterfaceqt/ffmpeg" \
	"${APPDIR}/usr/lib/plugins/platforms" \
	"${APPDIR}/usr/lib/qt6/plugins/platforms" \
	"${APPDIR}/usr/lib/qt6/plugins/wayland-shell-integration" \
	"${APPDIR}/usr/lib/qt6/plugins/wayland-decoration-client"

# Copy binary:
cp ${BUILD_DIR}/openterfaceQT ${APPDIR}/usr/bin/openterfaceQT.bin
chmod +x ${APPDIR}/usr/bin/openterfaceQT.bin

# Copy libraries:
#
# NOTE: DO NOT bundle GLIBC libraries (libc.so.6, libm.so.6, libpthread.so.0,
# 	etc.) The AppImage must use the system's GLIBC to avoid version
# 	conflicts. linuxdeploy correctly excludes these, and we rely on the
# 	AppRun script's LD_LIBRARY_PATH to ensure proper library loading order.
# NOTE: This is a heavily stripped down (aka made readable) version of the
# 	original code.
#
# Format of here document:
# 	E|W|F lpattern [tgtsub] [sdirs ...]
#       	where tgtsub is a subdirectory of /usr/lib and sdirs is a
#       	list of source directories to search through with a list of
#       	system library directorie always appended. When library
#       	specific sdirs are specified you must use . to install
#       	them in /usr/lib.
#       S list of additional search dirs. Inserted between library specific
#         sdirs and the system defaults.
#	Lines starting with anything else are ignored.
S=""
while read severity lpattern tgtsub search
do
	case $severity in
	F) severity=FATAL;;
	E) severity=ERROR;;
	W) severity=WARNING;;
	S) S="$lpattern $tgtsub $search"; continue;;
	*) continue;;
	esac
	copy_libraries "$lpattern" $severity \
		"$APPDIR/usr/lib/${tgtsub:-.}/" \
		$search $S \
		/usr/lib/${ARCH}-linux-gnu /lib/${ARCH}-linux-gnu \
		/lib64 /lib /usr/lib
done <<-EOF
# C++ runtime libraries (CRITICAL for Qt/C++ applications)
S
E libgcc_s.so
E libstdc++.so 

# Critical system libraries (libusb, libdrm, libudev)
S
E libusb*.so . /opt/ffmpeg/lib /opt
E libdrm.so
E libudev.so

# Coreutils support
S 
E libstdbuf.so . /usr/libexec/coreutils /opt

# JPEG libraries
S /opt/ffmpeg/lib
E libjpeg.so
E libturbojpeg.so
E libpostproc.so openterfaceqt/ffmpeg
W libmfx.so openterfaceqt/ffmpeg

# FFmpeg libraries -> AppImage bundle under /usr/lib/openterfaceqt/ffmpeg
S /opt/ffmpeg/lib
W libavdevice.so openterfaceqt/ffmpeg
W libavcodec.so openterfaceqt/ffmpeg
W libavformat.so openterfaceqt/ffmpeg
W libavutil.so openterfaceqt/ffmpeg
W libswscale.so openterfaceqt/ffmpeg
W libswresample.so openterfaceqt/ffmpeg
W libavfilter.so openterfaceqt/ffmpeg

# Compression and other system libraries
S
W libbz2.so
W libz.so
W liblzma.so

W libffi.so
W libgobject.so
W libgmodule.so
W libpcre.so
W libelf.so
W libdw.so

# EGL and GPU rendering libraries (with wildcard patterns to match all versions)
S
W libEGL.so
W libGL.so
W libGLX.so
W libGLESv2.so
W libglvnd.so
W libGLdispatch.so
W libOpenGL.so

# Qt platform plugins (CRITICAL for GUI applications)
S /opt/Qt6/plugins/platforms /usr/lib/qt6/plugins/platforms /usr/lib/${ARCH}-linux-gnu/qt6/plugins/platforms
E libqxcb.so plugins/platforms
W libqwayland-egl.so plugins/platforms
W libqwayland-generic.so plugins/platforms
W libqoffscreen.so plugins/platforms
W libqminimal.so plugins/platforms

# Wayland dependencies (required for wayland plugin)
S
W libwayland-client.so
W libwayland-cursor.so
W libwayland-egl.so
W libxkbcommon.so

# XCB dependencies (required by xcb plugin)
S
W libxcb-cursor.so
W libxcb.so

# Qt platform plugin libraries (also as system libraries for backup copy)
S /opt/Qt6/plugins/platforms /opt/Qt6/lib /usr/lib/qt6/plugins/platforms /usr/lib/${ARCH}-linux-gnu/qt6/plugins/platforms
W libqminimal.so
W libqoffscreen.so

# Essential GStreamer plugins for video capture
S /opt/gstreamer/lib/${ARCH}-linux-gnu/gstreamer-1.0 /opt/gstreamer/lib/gstreamer-1.0 /usr/lib/${ARCH}-linux-gnu/gstreamer-1.0 /usr/lib/gstreamer-1.0"
E libgstreamer-1.0.so gstreamer-1.0
E libgstvideo4linux2.so gstreamer-1.0
W libgstv4l2codecs.so gstreamer-1.0
W libgstjpeg.so gstreamer-1.0
W libgstcoreelements.so gstreamer-1.0
W libgstapp.so gstreamer-1.0
W libgstplayback.so gstreamer-1.0
# GStreamer >= 1.22 ships videoconvert/videoscale in libgstvideoconvertscale.so,
# older releases ship them as separate plugins - bundle whichever exists.
W libgstvideoconvertscale.so gstreamer-1.0
#W libgstvideoconvert.so gstreamer-1.0
#W libgstvideoscale.so gstreamer-1.0
W libgstvideotestsrc.so gstreamer-1.0
W libgstvideofilter.so gstreamer-1.0
W libgstvideorate.so gstreamer-1.0
W libgstximagesink.so gstreamer-1.0
W libgstxvimagesink.so gstreamer-1.0
W libgstpulseaudio.so gstreamer-1.0
W libgstaudioparsers.so gstreamer-1.0
W libgstaudioconvert.so gstreamer-1.0
W libgstaudioresample.so gstreamer-1.0
W libgstautodetect.so gstreamer-1.0
W libgsttypefindfunctions.so gstreamer-1.0

# System loader
S
W ld-linux-x86-64.so.2
EOF

# Without videoconvert/videoscale GStreamer cannot build the capture pipeline
# at all (the QImage fallback branch needs videoconvert too). Fail packaging
# instead of silently shipping an AppImage that shows a black video pane.
# Can't do this during copy, as we have ann either/or situation for the libs.
GST_BUNDLE_DIR="${APPDIR}/usr/lib/gstreamer-1.0"
GST_MISSING=""
[ -e "${GST_BUNDLE_DIR}/libgstvideoconvert.so" -o -e "${GST_BUNDLE_DIR}/libgstvideoconvertscale.so" ] || GST_MISSING="${GST_MISSING} videoconvert"
[ -e "${GST_BUNDLE_DIR}/libgstvideoscale.so" -o -e "${GST_BUNDLE_DIR}/libgstvideoconvertscale.so" ] || GST_MISSING="${GST_MISSING} videoscale"
[ -e "${GST_BUNDLE_DIR}/libgstvideotestsrc.so" ] || GST_MISSING="${GST_MISSING} videotestsrc"
[ -z "${GST_MISSING}" ] || fat "Bundled GStreamer is missing required plugins: ${GST_MISSING}"
 
# Diagnostic: Verify critical libraries were actually copied
msg "🔍 Diagnostic: Verifying GPU libraries in ${APPDIR}/usr/lib..."
msg=$(ls -1 ${APPDIR}/usr/lib/libEGL* 2>/dev/null) ||
	wrn "NO libEGL files found!"
[ -z "$msg" ] || dbg "$msg"
msg=$(ls -1 ${APPDIR}/usr/lib/libGL* 2>/dev/null) || wrn "NO libGL files found!"
[ -z "$msg" ] || dbg "$msg"

# Some statistics:
dbg "Total .so files in appimage/AppDir/usr/lib: $(find appimage/AppDir/usr/lib -maxdepth 1 -name "*.so*" \( -type f -o -type l \) -print 2>/dev/null | wc -l)"

# Normalize FFmpeg soname symlinks under the openterfaceqt/ffmpeg directory
if [ -d "${APPDIR}/usr/lib/openterfaceqt/ffmpeg" ]
then
	msg "🔧 Normalizing FFmpeg symlinks..."

	# Push library directory and avoid literal globbing.
	pushd "${APPDIR}/usr/lib/openterfaceqt/ffmpeg" >/dev/null
	shopt -s nullglob

	# Create symlinks for multi-dot versioned libraries (libname.so.1.2.3)
	for fullfile in *.so.*.*; do
		[ -f "$fullfile" ] || continue
		base=$(echo "$fullfile" | sed 's/\.so\..*//')
		soname=$(echo "$fullfile" | sed 's/\(.*\.so\.[0-9]*\)\.*.*/\1/')
		if [ "$soname" != "$fullfile" ]; then
			if [ ! -L "$soname" ] && [ ! -f "$soname" ]; then
				ln -sf "$fullfile" "$soname"
				dbg "Created symlink: $soname -> $fullfile"
			elif [ -f "$soname" ]; then
				rm -f "$soname"
				ln -sf "$fullfile" "$soname"
				dbg "Converted to symlink: $soname -> $fullfile"
			fi
		fi
		if [ ! -L "${base}.so" ] && [ ! -f "${base}.so" ]; then
			ln -sf "$fullfile" "${base}.so"
			dbg "Created symlink: ${base}.so -> $fullfile"
		fi
	done

	# Also handle single-dot sonames (libname.so.1)
	for fullfile in *.so.*; do
		[ -f "$fullfile" ] || continue
		base=$(echo "$fullfile" | sed 's/\.so\..*//')
		soname=$(echo "$fullfile" | sed 's/\(.*\.so\.[0-9]*\)\.*.*/\1/')
		if [ ! -L "$soname" ] && [ ! -f "$soname" ]; then
			ln -sf "$fullfile" "$soname"
			dbg "Created symlink: $soname -> $fullfile"
		fi
		if [ ! -L "${base}.so" ] && [ ! -f "${base}.so" ]; then
			ln -sf "$fullfile" "${base}.so"
			dbg "Created symlink: ${base}.so -> $fullfile"
		fi
	done

	# Pop library directory and allow literal globbing.
	popd >/dev/null
	shopt -u nullglob

	ok "FFmpeg symlink normalization complete."
fi

# Copy gst-plugin-scanner
# GStreamer needs a plugin scanner helper binary; many distributions put it
# under libexec/gstreamer-1.0 or under <prefix>/libexec/gstreamer-1.0.
# AppRun and main.cpp look for it at usr/libexec/gstreamer-1.0
echo "🔍 Looking for gst-plugin-scanner on build host/container..."
SCANNER_FOUND=""
for c in "/opt/gstreamer/libexec/gstreamer-1.0/gst-plugin-scanner" \
	"/opt/gstreamer/lib/${ARCH}-linux-gnu/libexec/gstreamer-1.0/gst-plugin-scanner" \
	"/usr/libexec/gstreamer-1.0/gst-plugin-scanner" \
	"/usr/lib/${ARCH}-linux-gnu/libexec/gstreamer-1.0/gst-plugin-scanner" \
	"/usr/lib/${ARCH}-linux-gnu/gstreamer-1.0/gst-plugin-scanner" \
	"/usr/lib/${ARCH}-linux-gnu/gstreamer1.0/gstreamer-1.0/gst-plugin-scanner" \
	"/usr/lib/gstreamer-1.0/gst-plugin-scanner" \
	"/usr/bin/gst-plugin-scanner"
do
	if [ -x "$c" ]; then
		cp -aP "$c" "${APPDIR}/usr/libexec/gstreamer-1.0/gst-plugin-scanner"
		chmod +x "${APPDIR}/usr/libexec/gstreamer-1.0/gst-plugin-scanner"
		SCANNER_FOUND="$c"
		ok "Copied gst-plugin-scanner from: $c"
		break
	fi
done
[ -n "$SCANNER_FOUND" ] ||
	wrn "No gst-plugin-scanner found in common locations; GStreamer will use host scanner if available"

# Install icons with both icon names:
#	1. com.openterface.openterfaceQT - for FreeDesktop icon theme lookup
#	2. openterfaceQT - as fallback for legacy applications
ICONDIR="$APPDIR/usr/share/icons/hicolor"
PMAPDIR="$APPDIR/usr/share/pixmaps"
ICON=/workspace/src/images/icon_256.png
cp $ICON "$ICONDIR/256x256/apps/openterfaceqt.png"
cp $ICON "$ICONDIR/256x256/apps/com.openterface.openterfaceQT.png"
cp $ICON "$PMAPDIR/openterfaceqt.png"
cp $ICON "$PMAPDIR/com.openterface.openterfaceQT.png"
cp $ICON "$APPDIR/openterfaceqt.png"
cp $ICON "$APPDIR/com.openterface.openterfaceQT.png"
ICON=/workspace/src/images/icon_128.png
cp $ICON "$ICONDIR/128x128/apps/openterfaceqt.png"
cp $ICON "$ICONDIR/128x128/apps/com.openterface.openterfaceQT.png"
ok "Initial AppImage setup complete"

# Continue to comprehensive AppImage creation section with Docker runtime support
# (This section was simplified and moved to the end of the script for proper runtime handling)
msg "🔧 Proceeding to AppImage creation with Docker runtime support"

# Create desktop file
#
# Keep Exec=openterfaceQT (NOT openterfaceQT.bin) so that linuxdeploy creates
# the desktop-integration symlink as usr/bin/openterfaceQT -> ../../AppRun,
# leaving the real ELF binary openterfaceQT.bin untouched.
#
# AppRun always calls .bin directly.
sed -e 's|^Exec=.*$|Exec=openterfaceQT|g' \
	"${SRC}/packaging/com.openterface.openterfaceQT.desktop" \
	>"${APPDIR}/usr/share/applications/openterfaceqt.desktop"

# Copy desktop file to root of AppDir
cp "${APPDIR}/usr/share/applications/openterfaceqt.desktop" "${DESKTOP_OUT}"

# Try to find glibc version directory for proper loader setup
GLIBC_VERSION=$(ldd --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1 || echo "unknown")

# Copy metainfo file
cp "${SRC}/packaging/com.openterface.openterfaceQT.metainfo.xml" "${APPDIR}/usr/share/metainfo/" || fat "Cannot copy metainfo file"

# Copy translations
cp "${BUILD_DIR}"/openterface_*.qm "${APPDIR}/usr/share/openterfaceQT/translations/"

# Prefer preinstalled linuxdeploy and plugin in the image; fallback to download
TOOLS_DIR="${APPIMAGE_DIR}/tools"
LINUXDEPLOY_BIN=""

# Ensure AppImages run inside containers without FUSE (also set in Dockerfile)
export APPIMAGE_EXTRACT_AND_RUN=${APPIMAGE_EXTRACT_AND_RUN:-1}

# Check for pre-downloaded runtime from Docker image
mkdir -p "${TOOLS_DIR}"
DOCKER_RUNTIME_FILE="/opt/appimage-runtime/runtime-${APPIMAGE_ARCH}"
TOOLS_RUNTIME_FILE="${TOOLS_DIR}/runtime-${APPIMAGE_ARCH}"

# Prioritize pre-downloaded runtime from Docker image
if [ -f "${DOCKER_RUNTIME_FILE}" ]; then
	echo "✓ Using pre-downloaded runtime from Docker environment: ${DOCKER_RUNTIME_FILE}"
	cp "${DOCKER_RUNTIME_FILE}" "${TOOLS_RUNTIME_FILE}"
	chmod +x "${TOOLS_RUNTIME_FILE}"
	echo "✓ Runtime copied to tools directory: ${TOOLS_RUNTIME_FILE}"
elif [ -f "${TOOLS_RUNTIME_FILE}" ]; then
	echo "✓ Runtime already available in tools directory: ${TOOLS_RUNTIME_FILE}"
else
	echo "⚠ Warning: No pre-downloaded runtime found at ${DOCKER_RUNTIME_FILE}"
	echo "⚠ AppImage creation will proceed without custom runtime (linuxdeploy will download automatically)"
fi

if command -v linuxdeploy >/dev/null 2>&1 && command -v linuxdeploy-plugin-qt >/dev/null 2>&1; then
	echo "Using preinstalled linuxdeploy and linuxdeploy-plugin-qt"
	LINUXDEPLOY_BIN="$(command -v linuxdeploy)"
	# Ensure the plugin directory is on PATH
	PLUGIN_DIR="$(dirname "$(command -v linuxdeploy-plugin-qt)")"
	export PATH="${PLUGIN_DIR}:${PATH}"
else
	echo "linuxdeploy not found in image; downloading tools..."
	# Download helper (curl with wget fallback)
	_fetch() {
		local url="$1" out="$2"
		if command -v curl >/dev/null 2>&1; then
			curl -fL "${url}" -o "${out}"
		elif command -v wget >/dev/null 2>&1; then
			wget -qO "${out}" "${url}"
		else
			echo "Neither curl nor wget found for downloading ${url}" >&2
			return 1
		fi
	}

	mkdir -p "${TOOLS_DIR}"
	pushd "${TOOLS_DIR}" >/dev/null
	LDEPLOY_URL="https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-${ARCH}.AppImage"
	LDEPLOY_QT_URL="https://github.com/linuxdeploy/linuxdeploy-plugin-qt/releases/download/continuous/linuxdeploy-plugin-qt-${APPIMAGE_ARCH}.AppImage"
	
	echo "Downloading linuxdeploy from ${LDEPLOY_URL}"
	_fetch "${LDEPLOY_URL}" linuxdeploy.AppImage
	echo "Downloading linuxdeploy-plugin-qt from ${LDEPLOY_QT_URL}"
	_fetch "${LDEPLOY_QT_URL}" linuxdeploy-plugin-qt.AppImage
	
	# Use pre-downloaded runtime from Docker image if available
	if [ -f "/opt/appimage-runtime/runtime-${APPIMAGE_ARCH}" ]; then
		echo "✓ Using pre-downloaded runtime from Docker environment"
		cp "/opt/appimage-runtime/runtime-${APPIMAGE_ARCH}" "runtime-${APPIMAGE_ARCH}"
		chmod +x "runtime-${APPIMAGE_ARCH}"
		echo "✓ Runtime copied successfully"
	else
		echo "⚠ No pre-downloaded runtime found, linuxdeploy will download automatically"
	fi
	
	chmod +x linuxdeploy.AppImage linuxdeploy-plugin-qt.AppImage
	# Use the downloaded linuxdeploy and make plugin available on PATH
	LINUXDEPLOY_BIN="${TOOLS_DIR}/linuxdeploy.AppImage"
	export PATH="${TOOLS_DIR}:${PATH}"
	popd >/dev/null
fi

# Build AppImage with comprehensive runtime support
pushd "${APPIMAGE_DIR}" >/dev/null

# For static builds, skip Qt plugin since Qt is statically linked
if [ "${OPENTERFACE_BUILD_STATIC}" != "ON" ]; then
	USE_QT_PLUGIN=true
else
	USE_QT_PLUGIN=false
fi

# Set runtime file path - prioritize Docker pre-downloaded runtime
RUNTIME_FILE="${TOOLS_DIR}/runtime-${APPIMAGE_ARCH}"
DOCKER_RUNTIME_FILE="/opt/appimage-runtime/runtime-${APPIMAGE_ARCH}"
LOCAL_RUNTIME_FILE="./runtime-${APPIMAGE_ARCH}"

# Copy runtime to current directory where appimagetool can find it
if [ -f "${RUNTIME_FILE}" ]; then
	echo "✓ Copying runtime to AppImage build directory for appimagetool"
	cp "${RUNTIME_FILE}" "${LOCAL_RUNTIME_FILE}"
	chmod +x "${LOCAL_RUNTIME_FILE}"
elif [ -f "${DOCKER_RUNTIME_FILE}" ]; then
	echo "✓ Copying Docker runtime to AppImage build directory for appimagetool"
	cp "${DOCKER_RUNTIME_FILE}" "${LOCAL_RUNTIME_FILE}"
	chmod +x "${LOCAL_RUNTIME_FILE}"
	RUNTIME_FILE="${LOCAL_RUNTIME_FILE}"
fi
DOCKER_RUNTIME_FILE="/opt/appimage-runtime/runtime-${APPIMAGE_ARCH}"

# Ensure we have the runtime from Docker environment
if [ -f "${DOCKER_RUNTIME_FILE}" ] && [ ! -f "${RUNTIME_FILE}" ]; then
	echo "✓ Copying Docker pre-downloaded runtime to tools directory"
	cp "${DOCKER_RUNTIME_FILE}" "${RUNTIME_FILE}"
	chmod +x "${RUNTIME_FILE}"
fi

if [ -f "${LOCAL_RUNTIME_FILE}" ]; then
	# Set multiple environment variables that appimagetool might recognize
	export APPIMAGE_RUNTIME_FILE="${LOCAL_RUNTIME_FILE}"
	export RUNTIME_FILE="${LOCAL_RUNTIME_FILE}"
	export APPIMAGETOOL_RUNTIME="${LOCAL_RUNTIME_FILE}"
	export RUNTIME="${LOCAL_RUNTIME_FILE}"
	# Unset UPDATE_INFORMATION to avoid format errors in appimagetool
	unset UPDATE_INFORMATION
	unset LDAI_UPDATE_INFORMATION
	echo "✓ Using local runtime file: ${LOCAL_RUNTIME_FILE}"
	ls -lh "${LOCAL_RUNTIME_FILE}"
elif [ -f "${DOCKER_RUNTIME_FILE}" ]; then
	# Use Docker runtime directly if tools copy doesn't exist
	echo "✓ Using Docker runtime directly: ${DOCKER_RUNTIME_FILE}"
	export APPIMAGE_RUNTIME_FILE="${DOCKER_RUNTIME_FILE}"
	export RUNTIME_FILE="${DOCKER_RUNTIME_FILE}"
	export APPIMAGETOOL_RUNTIME="${DOCKER_RUNTIME_FILE}"
	export RUNTIME="${DOCKER_RUNTIME_FILE}"
	unset UPDATE_INFORMATION
	unset LDAI_UPDATE_INFORMATION
	ls -lh "${DOCKER_RUNTIME_FILE}"
else
	echo "⚠ Warning: No runtime file available, linuxdeploy will download it automatically"
	unset APPIMAGE_RUNTIME_FILE
	unset RUNTIME_FILE
	unset APPIMAGETOOL_RUNTIME
	unset RUNTIME
	unset UPDATE_INFORMATION
	unset LDAI_UPDATE_INFORMATION
fi

# Debug: Show environment variables for AppImage creation
echo "=== AppImage Build Environment ==="
echo "APPIMAGE_EXTRACT_AND_RUN=${APPIMAGE_EXTRACT_AND_RUN}"
echo "APPIMAGE_RUNTIME_FILE=${APPIMAGE_RUNTIME_FILE:-<not set>}"
echo "RUNTIME_FILE=${RUNTIME_FILE:-<not set>}"
echo "APPIMAGETOOL_RUNTIME=${APPIMAGETOOL_RUNTIME:-<not set>}"
echo "RUNTIME=${RUNTIME:-<not set>}"
echo "UPDATE_INFORMATION=${UPDATE_INFORMATION:-<not set>}"
echo "LINUXDEPLOY_BIN=${LINUXDEPLOY_BIN}"
echo "================================="

# Debug: Show the actual linuxdeploy command being executed
echo "=== LinuxDeploy Command Debug ==="
echo "LINUXDEPLOY_BIN: ${LINUXDEPLOY_BIN}"
echo "APPDIR: ${APPDIR}"
echo "DESKTOP_OUT: ${DESKTOP_OUT}"
echo "ICON_SRC: ${ICON}"
echo "USE_QT_PLUGIN: ${USE_QT_PLUGIN}"
echo "================================"

# Debug: Show what libraries are in the AppDir before linuxdeploy
echo "📊 Verifying libusb in AppDir before linuxdeploy..."
LIBUSB_COUNT=$(find "${APPDIR}/usr/lib" -name "libusb*" 2>/dev/null | wc -l)
if [ "$LIBUSB_COUNT" -gt 0 ]; then
	echo "  ✅ libusb found in AppDir:"
	find "${APPDIR}/usr/lib" -name "libusb*" 2>/dev/null | while read -r lib; do
		echo "     - $lib"
		file "$lib" 2>/dev/null || echo "       (unable to determine file type)"
	done
else
	echo "  ❌ libusb NOT found in AppDir!"
	echo "  Available system libraries:"
	ls -lh "${APPDIR}/usr/lib/" | head -20
fi
echo ""

# Set LD_LIBRARY_PATH to include ffmpeg and gstreamer libraries for dependency resolution
export LD_LIBRARY_PATH="/opt/ffmpeg/lib:/opt/gstreamer/lib:/opt/gstreamer/lib/${ARCH}-linux-gnu:/opt/Qt6/lib:$LD_LIBRARY_PATH"
export PATH="/opt/Qt6/bin:$PATH"
export QT_PLUGIN_PATH="/opt/Qt6/plugins:$QT_PLUGIN_PATH"
export QML2_IMPORT_PATH="/opt/Qt6/qml:$QML2_IMPORT_PATH"

# CRITICAL: Save libraries BEFORE linuxdeploy (it will blacklist some)
echo "📦 Pre-linuxdeploy: Saving critical libraries to prevent blacklisting..."
mkdir -p "${APPDIR}/usr/lib/linuxdeploy_protected"

# These libraries WILL be blacklisted by linuxdeploy - save them now
PROTECTED_LIBS=(
	# NOTE: DO NOT protect GLIBC libraries - they should use system versions
	# Protecting them causes version conflicts like "GLIBC_2.38 not found"
	# C++ runtime libraries
	"libgcc_s.so.1"
	"libstdc++.so.6"
	"ld-linux-x86-64.so.2"
	# GPU/EGL rendering libraries that are also blacklisted but needed
	"libEGL.so.1"
	"libEGL.so"
	"libGLX.so.0"
	"libGLX.so"
	"libGL.so.1"
	"libGL.so"
	"libGLESv2.so.2"
	"libGLESv2.so"
	"libglvnd.so.0"
	"libglvnd.so"
	"libGLdispatch.so.0"
	"libGLdispatch.so"
	"libOpenGL.so.0"
	"libOpenGL.so"
	# Additional rendering support
	"libxcb-dri2.so.0"
	"libxcb-dri3.so.0"
	"libxcb-present.so.0"
	"libxcb-sync.so.1"
	"libxshmfence.so.1"
	"libdrm.so.2"
	"libdrm.so"
	# Compression libraries
	"libbz2.so.1"
	"libbz2.so"
)

PROTECTED_COUNT=0
PROTECTED_MISSING=0
for lib in "${PROTECTED_LIBS[@]}"; do
	# Use wildcard to match versioned libraries (e.g., libEGL.so.1, libEGL.so.0, libEGL.so)
	# Find all files/symlinks matching this pattern
	lib_found=0
	
	if [ -f "${APPDIR}/usr/lib/${lib}" ] || [ -L "${APPDIR}/usr/lib/${lib}" ]; then
		# Exact match found
		cp -P "${APPDIR}/usr/lib/${lib}" "${APPDIR}/usr/lib/linuxdeploy_protected/" 2>/dev/null || true
		PROTECTED_COUNT=$((PROTECTED_COUNT + 1))
		lib_found=1
	else
		# Try wildcard match for versioned libraries
		shopt -s nullglob
		for libfile in "${APPDIR}/usr/lib/${lib}"*; do
			if [ -f "$libfile" ] || [ -L "$libfile" ]; then
				cp -P "$libfile" "${APPDIR}/usr/lib/linuxdeploy_protected/" 2>/dev/null || true
				PROTECTED_COUNT=$((PROTECTED_COUNT + 1))
				lib_found=1
			fi
		done
		shopt -u nullglob
	fi
	
	if [ $lib_found -eq 0 ]; then
		PROTECTED_MISSING=$((PROTECTED_MISSING + 1))
	fi
done
echo "  ✓ Protected $PROTECTED_COUNT critical libraries"
if [ $PROTECTED_MISSING -gt 0 ]; then
	echo "  ⚠️  $PROTECTED_MISSING libraries were not found to backup"
	echo "     First 20 libs in ${APPDIR}/usr/lib:"
	ls -1 "${APPDIR}/usr/lib" 2>/dev/null | head -20 | sed 's/^/       /'
fi

# Build the command with proper argument handling
LINUXDEPLOY_ARGS=(
	"--appdir" "${APPDIR}"
	"--executable" "${APPDIR}/usr/bin/openterfaceQT.bin"
	"--desktop-file" "${DESKTOP_OUT}"
)

if [ -n "${ICON}" ]; then
	LINUXDEPLOY_ARGS+=("--icon-file" "${ICON}")
fi

if [ "${USE_QT_PLUGIN}" = "true" ]; then
	LINUXDEPLOY_ARGS+=("--plugin" "qt")
fi

LINUXDEPLOY_ARGS+=("--output" "appimage")

echo "Final command: ${LINUXDEPLOY_BIN}" "${LINUXDEPLOY_ARGS[@]}"

# Try running linuxdeploy without the appimage output plugin first
LINUXDEPLOY_ARGS_NO_OUTPUT=(
	"--appdir" "${APPDIR}"
	"--executable" "${APPDIR}/usr/bin/openterfaceQT.bin"
	"--desktop-file" "${DESKTOP_OUT}"
)

if [ -n "${ICON}" ]; then
	LINUXDEPLOY_ARGS_NO_OUTPUT+=("--icon-file" "${ICON}")
fi

if [ "${USE_QT_PLUGIN}" = "true" ]; then
	LINUXDEPLOY_ARGS_NO_OUTPUT+=("--plugin" "qt")
fi

echo "Running linuxdeploy without output plugin..."
echo "⚠️  IMPORTANT: linuxdeploy will skip/blacklist certain libraries"
echo "    (GLIBC libraries are correctly excluded - the AppImage uses system GLIBC)"
echo "    (libgcc_s.so.1 and libstdc++.so.6 have been backed up and will be restored)"
echo ""

# Run linuxdeploy with environment variable to suppress some warnings
# Note: linuxdeploy will still skip blacklisted libraries, but we'll restore them after
export LDAI_SKIP_GLIBC=1
if "${LINUXDEPLOY_BIN}" "${LINUXDEPLOY_ARGS_NO_OUTPUT[@]}"; then
	echo "✓ linuxdeploy completed"
else
	LINUXDEPLOY_EXIT=$?
	echo "⚠️  linuxdeploy exited with code: $LINUXDEPLOY_EXIT"
	if [ $LINUXDEPLOY_EXIT -eq 141 ] || [ $LINUXDEPLOY_EXIT -eq 3 ]; then
		echo "   (This may be a SIGPIPE or similar non-critical error)"
		echo "   Continuing..."
	fi
fi

# CRITICAL FIX: Restore critical libraries that linuxdeploy blacklisted
echo "🔧 Restoring critical C++ runtime libraries that linuxdeploy skipped..."
echo "   (linuxdeploy correctly excludes GLIBC libraries - the AppImage uses system versions)"
echo "   (Restoring only: libgcc_s.so.1, libstdc++.so.6, ld-linux-x86-64.so.2)"

if [ -d "${APPDIR}/usr/lib/linuxdeploy_protected" ]; then
	echo "   Checking protected backup directory..."
	PROTECTED_LIB_COUNT=$(find "${APPDIR}/usr/lib/linuxdeploy_protected" -type f 2>/dev/null | wc -l)
	echo "   Found $PROTECTED_LIB_COUNT libraries in protected backup"
	
	if [ "$PROTECTED_LIB_COUNT" -eq 0 ]; then
		echo "   ⚠️  No files in protected directory!"
		ls -la "${APPDIR}/usr/lib/linuxdeploy_protected/" 2>/dev/null | head -10
	else
		RESTORED_COUNT=0
		for lib in "${APPDIR}/usr/lib/linuxdeploy_protected"/*; do
			if [ -f "$lib" ]; then
				libname=$(basename "$lib")
				# Check if linuxdeploy removed it
				if [ ! -f "${APPDIR}/usr/lib/$libname" ]; then
					echo "  ✓ Restoring blacklisted library: $libname"
					cp -P "$lib" "${APPDIR}/usr/lib/" || echo "    ⚠️  Failed to restore $libname"
					RESTORED_COUNT=$((RESTORED_COUNT + 1))
				else
					echo "  ℹ️  Library still present: $libname"
				fi
			fi
		done
		echo "  ✅ Restored $RESTORED_COUNT blacklisted libraries"
	fi
	rm -rf "${APPDIR}/usr/lib/linuxdeploy_protected"
else
	echo "  ⚠️  No protected backup found!"
	echo "     Available at: ${APPDIR}/usr/lib/linuxdeploy_protected"
fi

# Double-check critical libraries are present
echo ""
echo "📊 Verifying critical libraries after linuxdeploy..."
# NOTE: We do NOT verify GLIBC libraries here because they should NOT be bundled
# The AppImage uses the system's GLIBC to avoid version conflicts
CRITICAL_LIBS=("libgcc_s.so.1" "libstdc++.so.6")
MISSING_LIBS=()
for lib in "${CRITICAL_LIBS[@]}"; do
	if [ -f "${APPDIR}/usr/lib/$lib" ]; then
		echo "  ✓ Present: $lib"
	else
		echo "  ✗ MISSING: $lib"
		MISSING_LIBS+=("$lib")
	fi
done

if [ ${#MISSING_LIBS[@]} -gt 0 ]; then
	echo ""
	echo "❌ ERROR: Critical C++ runtime libraries are missing!"
	echo "Missing: ${MISSING_LIBS[*]}"
	echo ""
	echo "Available C++ libraries in ${APPDIR}/usr/lib:"
	ls -1 "${APPDIR}/usr/lib" | grep -E "libgcc|libstdc" | head -20
	echo ""
	echo "📍 Diagnostic Info:"
	echo "   Total files in ${APPDIR}/usr/lib:"
	find "${APPDIR}/usr/lib" -type f 2>/dev/null | wc -l
	echo "   Subdirectories:"
	ls -d "${APPDIR}/usr/lib"/*/ 2>/dev/null | sed 's|^|   |'
	echo ""
	echo "⚠️  CRITICAL: C++ runtime libraries may not have been copied to AppDir before linuxdeploy!"
	echo "   Check that copy_libraries() function is working correctly."
	echo ""
fi

# After linuxdeploy, clean up coreutils libraries that have incompatible GLIBC versions
echo "🔧 Cleaning up incompatible coreutils libraries..."

# NOTE: GLIBC libraries (libc.so.6, libm.so.6, etc.) are NOT bundled in the AppImage
# The AppImage uses the system's GLIBC to avoid version conflicts like "GLIBC_2.38 not found"
# The LD_LIBRARY_PATH in AppRun ensures proper library loading order

# Remove coreutils binaries
PROBLEM_BINS=(
    "stdbuf"           # Most common culprit - uses libstdbuf.so
    "time"             # May also have version issues
    "timeout"          # May have version issues
)

for bin in "${PROBLEM_BINS[@]}"; do
    if [ -f "${APPDIR}/usr/bin/$bin" ]; then
        echo "  🗑️  Removing ${bin} to avoid GLIBC compatibility issues"
        rm -f "${APPDIR}/usr/bin/$bin"
    fi
done

# Remove problematic coreutils libraries from /usr/lib/
echo "Removing coreutils libraries that have incompatible GLIBC versions..."
rm -f "${APPDIR}/usr/lib/libstdbuf.so"* 2>/dev/null || true
rm -f "${APPDIR}/lib/libstdbuf.so"* 2>/dev/null || true
echo "  🗑️  Removed libstdbuf.so variants"

# Remove the coreutils libexec directory
rm -rf "${APPDIR}/usr/libexec/coreutils/" 2>/dev/null || true
rm -rf "${APPDIR}/libexec/coreutils/" 2>/dev/null || true
echo "  ✓ GLIBC and coreutils libraries removed - will use host system versions"

# Safeguard: linuxdeploy (or its Qt plugin) can replace openterfaceQT.bin with a symlink
# pointing back to AppRun for desktop integration. That would cause AppRun to exec itself
# in a loop. Restore the real ELF if that happened.
# We check for BOTH a symlink AND a non-ELF file (linuxdeploy may copy the shell script
# wrapper rather than create a symlink, depending on its version).
_bin="${APPDIR}/usr/bin/openterfaceQT.bin"
if [ -L "$_bin" ] || ! file "$_bin" 2>/dev/null | grep -q 'ELF'; then
	echo "⚠️  openterfaceQT.bin was replaced by linuxdeploy (symlink or non-ELF); restoring real binary"
	rm -f "$_bin"
	cp "${BUILD_DIR}/openterfaceQT" "$_bin"
	chmod +x "$_bin"
	echo "✓ Restored openterfaceQT.bin as real ELF binary"
fi
unset _bin

# Copy AppRun script from packaging directory with proper environment setup
cp "${SRC}/packaging/appimage/AppRun" "${APPDIR}/AppRun"
chmod +x "${APPDIR}/AppRun"
echo "✓ AppRun script copied from packaging/appimage/"

# Then use appimagetool directly with explicit runtime file
echo "Running appimagetool with explicit runtime file..."
APPIMAGETOOL_FAILED=0
if command -v appimagetool >/dev/null 2>&1; then
	if [ -f "${RUNTIME_FILE}" ]; then
		echo "Using runtime file: ${RUNTIME_FILE}"
		appimagetool --runtime-file "${RUNTIME_FILE}" "${APPDIR}" || APPIMAGETOOL_FAILED=$?
	else
		echo "Warning: Runtime file not found, running appimagetool without runtime file"
		appimagetool "${APPDIR}" || APPIMAGETOOL_FAILED=$?
	fi
else
	echo "appimagetool not found, trying linuxdeploy with output plugin..."
	LINUXDEPLOY_ARGS+=("--output" "appimage")
	"${LINUXDEPLOY_BIN}" "${LINUXDEPLOY_ARGS[@]}" || APPIMAGETOOL_FAILED=$?
fi

if [ $APPIMAGETOOL_FAILED -ne 0 ] && [ $APPIMAGETOOL_FAILED -ne 141 ]; then
	echo "⚠️  appimagetool exited with code: $APPIMAGETOOL_FAILED"
fi

# Normalize output name
APPIMAGE_FILENAME="openterfaceQT_${VERSION}_${APPIMAGE_ARCH}.AppImage"
# Move whichever AppImage got produced
FOUND_APPIMAGE=$(ls -1 *.AppImage 2>/dev/null | grep -v -E '^linuxdeploy|^linuxdeploy-plugin-qt' | head -n1 || echo "")
if [ -n "${FOUND_APPIMAGE}" ]; then
	chmod +x "${FOUND_APPIMAGE}"
	mv "${FOUND_APPIMAGE}" "${APPIMAGE_OUT}/${APPIMAGE_FILENAME}"
	echo "✅ AppImage created at ${APPIMAGE_OUT}/${APPIMAGE_FILENAME}"
	echo "📊 AppImage size: $(ls -lh "${APPIMAGE_OUT}/${APPIMAGE_FILENAME}" | awk '{print $5}')"
else
	echo "⚠️  No AppImage found in current directory"
	echo "Checking for any .AppImage files in system..."
	find . -name "*.AppImage" -type f 2>/dev/null | head -5 | while read -r img; do
		echo "  Found: $img"
		if [ -f "$img" ]; then
			SIZE=$(ls -lh "$img" | awk '{print $5}')
			echo "  Size: $SIZE"
			chmod +x "$img"
			FINAL_NAME=$(basename "$img" | sed "s/_continuous/${VERSION}/g")
			mv "$img" "${APPIMAGE_OUT}/${FINAL_NAME}" 2>/dev/null && echo "  ✓ Moved to ${APPIMAGE_OUT}/${FINAL_NAME}" || echo "  ✗ Failed to move"
		fi
	done
	
	# Final check
	if ls "${APPIMAGE_OUT}"/*.AppImage >/dev/null 2>&1; then
		echo "✅ AppImage created successfully"
		ls -lh "${APPIMAGE_OUT}"/*.AppImage
	else
		echo "❌ Error: AppImage build did not produce an output." >&2
		exit 1
	fi
fi

popd >/dev/null
