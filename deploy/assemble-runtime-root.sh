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
for command in sh bash cat chmod chown cp curl date find getent id ls mkdir mv readlink rm rmdir sha256sum sleep sqlite3 stat test touch; do
  path=$(command -v "$command")
  case "$path" in /*) ;; *) path="/usr/bin/$command";; esac
  copy "$(readlink -f "$path")"
  case "$path" in /bin/*) path="/usr$path";; esac
  [ ! -L "$path" ] || copy "$path"
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
mkdir -p "$root/tmp" "$root/run/codexone" "$root/var/lib/codexone"
chmod 1777 "$root/tmp"
chown 10001:10001 "$root/var/lib/codexone"
chmod 700 "$root/var/lib/codexone"
