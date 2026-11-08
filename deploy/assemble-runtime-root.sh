#!/bin/sh
set -eu
# Use the pinned Ubuntu Swift image as the file and ABI source.
# Resolve ELF dependencies before copying the filesystem into the final image.
root=/runtime-root
binary=$1
mkdir -p "$root"
copy() {
  cp -a --parents "$@" "$root"
}
# Keep the Compose initializer, documented maintenance tools and resource probes.
for command in sh awk bash cat chmod chown cp curl date env find getconf getent id ls mkdir mv readlink rm rmdir sha256sum sleep sqlite3 stat test touch wc; do
  path=$(command -v "$command")
  case "$path" in /*) ;; *) path="/usr/bin/$command";; esac
  resolved=$(readlink -f "$path")
  copy "$resolved"
  case "$path" in /bin/*) path="/usr$path";; esac
  # Point aliases directly at the copied executable, without /etc/alternatives.
  [ "$path" = "$resolved" ] || ln -s "$resolved" "$root$path"
done
copy /bin /sbin /lib /lib64 /etc/passwd /etc/group /etc/nsswitch.conf /etc/ssl /usr/share/zoneinfo /usr/share/ca-certificates /etc/os-release /usr/lib/os-release
for path in "$root"/usr/bin/* "$binary"; do
  dependencies=$(ldd "$path")
  if printf '%s\n' "$dependencies" | grep -q 'not found'; then exit 1; fi
  printf '%s\n' "$dependencies" | awk '$2=="=>" && $3~/^\// {print $3} $1~/^\// {print $1}' | while IFS= read -r library; do
    resolved=$(readlink -f "$library")
    copy "$resolved"
    case "$library" in /lib/*|/lib64/*) library="/usr$library";; esac
    [ "$library" = "$resolved" ] || copy "$library"
  done
done
# glibc and OpenSSL can load these modules at runtime, outside the ldd graph.
for directory in /usr/lib/x86_64-linux-gnu/gconv /usr/lib/x86_64-linux-gnu/ossl-modules; do
  [ ! -d "$directory" ] || copy "$directory"
done
copy /var/lib/dpkg/status
find /usr/share/doc -name copyright -exec cp -a --parents {} "$root" \;
mkdir -p "$root/opt" "$root/tmp" "$root/run/codexone" "$root/var/lib/codexone"
chmod 1777 "$root/tmp"
chown 10001:10001 "$root/var/lib/codexone"
chmod 700 "$root/var/lib/codexone"

# Normalize copied file metadata so identical runtime inputs can share a layer across releases.
find "$root" -exec touch -h -d @0 {} +
