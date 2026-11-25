#!/usr/bin/env bash
# Ubuntu/Debian single-machine BDA practical setup. Run as your normal user.
# Requested primary Huawei download: https://repo.huaweicloud.com/apache/hbase/2.4.18/hbase-2.4.18-bin.tar.gz
set -Eeuo pipefail
[[ $EUID -ne 0 ]] || { echo 'Run with bash as your login user (sudo is used only where needed).' >&2; exit 1; }
ROOT="$HOME/.bda-lab-setup"
TOOLS="$HOME/bda-lab-tools"
CACHE="$ROOT/downloads"
ENV_DIR="$HOME/.bda-lab-env.d"
mkdir -p "$ROOT/backups" "$ROOT/logs" "$CACHE" "$TOOLS" "$ENV_DIR"
LOG="$ROOT/logs/$(basename "$0" .sh)-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1
trap 'code=$?; echo "[ERROR] Line ${LINENO}: command failed (exit $code). Log: $LOG" >&2' ERR
note() { printf '\n[SETUP] %s\n' "$*"; }
warn() { printf '\n[WARNING] %s\n' "$*" >&2; }
fail() { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }
need_sudo() { if (( EUID==0 )); then "$@"; else command -v sudo >/dev/null || fail 'sudo not installed'; sudo "$@"; fi; }
APT_UPDATED=0
install_pkgs() {
  command -v apt-get >/dev/null || fail 'Automatic packages require Ubuntu/Debian apt-get.'
  if (( ! APT_UPDATED )); then need_sudo apt-get update; APT_UPDATED=1; fi
  need_sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}
require_cmd() { command -v "$1" >/dev/null 2>&1 || install_pkgs "$2"; command -v "$1" >/dev/null 2>&1 || fail "Cannot install $1"; }
base_tools() {
  require_cmd wget wget
  require_cmd tar tar
  require_cmd curl curl
  require_cmd python3 python3
}
valid_java8() {
  [[ -n "${1:-}" && -x "$1/bin/java" && -x "$1/bin/javac" ]] || return 1
  "$1/bin/java" -version 2>&1 | head -1 | grep -Eq 'version "(1\.8\.|8[.+])'
}
find_java8() {
  local x
  for x in "${BDA_JAVA8_HOME:-}" "${JAVA_HOME:-}" \
    /usr/lib/jvm/java-8-openjdk-* /usr/lib/jvm/temurin-8-jdk-* \
    "$HOME"/.sdkman/candidates/java/8* "$HOME/.local/opt/temurin8-hadoop-lab"; do
    [[ -n "$x" ]] || continue
    if valid_java8 "$x"; then JAVA_HOME="$(readlink -f "$x")"; export JAVA_HOME; return 0; fi
  done
  if command -v java >/dev/null 2>&1; then
    x="$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")"
    if valid_java8 "$x"; then JAVA_HOME="$x"; export JAVA_HOME; return 0; fi
  fi
  return 1
}
ensure_java8() {
  if ! find_java8; then
    note 'Installing Java 8 (required by Hadoop 3.2.3/Hive 3.1.2).'
    if apt-cache show openjdk-8-jdk 2>/dev/null | grep -q '^Package: '; then
      install_pkgs openjdk-8-jdk || warn "openjdk-8-jdk package install failed; trying Temurin 8."
    fi
    if ! find_java8; then
      require_cmd gpg gnupg
      . /etc/os-release
      local codename="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
      [[ -n "$codename" ]] || fail 'Cannot detect Ubuntu/Debian codename.'
      curl -fL --retry 3 --connect-timeout 15 -o "$ROOT/adoptium-key.asc" \
        https://packages.adoptium.net/artifactory/api/gpg/key/public
      gpg --batch --yes --dearmor -o "$ROOT/adoptium.gpg" "$ROOT/adoptium-key.asc"
      need_sudo install -m 0644 "$ROOT/adoptium.gpg" /usr/share/keyrings/bda-adoptium.gpg
      echo "deb [signed-by=/usr/share/keyrings/bda-adoptium.gpg] https://packages.adoptium.net/artifactory/deb $codename main" > "$ROOT/bda-adoptium.list"
      need_sudo install -m 0644 "$ROOT/bda-adoptium.list" /etc/apt/sources.list.d/bda-adoptium.list
      need_sudo apt-get update; APT_UPDATED=1
      need_sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y temurin-8-jdk
    fi
  fi
  find_java8 || fail 'Java 8 JDK not found. Install Java 8 and retry, or set BDA_JAVA8_HOME.'
  export PATH="$JAVA_HOME/bin:$PATH"
  note "Java 8 ready: $JAVA_HOME"
}
# Downloads are validated as genuine gzip/tar archives; corrupt downloads are retried.
archive_download() {
  local dest="$1" url; shift
  if [[ -s "$dest" ]] && tar -tzf "$dest" >/dev/null 2>&1; then note "Cached archive: $dest"; return 0; fi
  rm -f "$dest" "$dest.part"
  for url in "$@"; do
    note "Download: $url"
    if wget -c --tries=3 --timeout=35 -O "$dest.part" "$url"; then
      if tar -tzf "$dest.part" >/dev/null 2>&1; then mv "$dest.part" "$dest"; return 0; fi
      warn "Archive verification failed: $url"
    else
      warn "Mirror unavailable: $url"
    fi
    rm -f "$dest.part"   # Never resume bytes from a different mirror.
  done
  fail "All download sources failed for $(basename "$dest")."
}
archive_install() {
  local arc="$1" dirname="$2" destination="$3" tmp
  [[ ! -e "$destination" ]] || fail "Existing directory cannot be replaced safely: $destination"
  tmp="$(mktemp -d "$TOOLS/.extract.XXXXXXXX")"
  if ! tar -xzf "$arc" -C "$tmp"; then rm -rf "$tmp"; fail "Cannot extract $arc"; fi
  [[ -d "$tmp/$dirname" ]] || { rm -rf "$tmp"; fail "Wrong archive layout for $dirname"; }
  mv "$tmp/$dirname" "$destination"
  rmdir "$tmp"
}
backup() {
  [[ -e "$1" ]] || return 0
  local dst="$ROOT/backups/$(basename "$1").$(date +%Y%m%d-%H%M%S).$$"
  cp -a "$1" "$dst"; note "Config backup: $dst"
}
# Write configuration using sudo only if a previous system install is root-owned.
safe_write() {
  local path="$1" tmp
  tmp="$(mktemp "$ROOT/config.XXXXXXXX")"
  cat > "$tmp"
  if [[ -w "$path" || ( ! -e "$path" && -w "$(dirname "$path")" ) ]]; then
    install -m 0644 "$tmp" "$path"
  else
    need_sudo install -m 0644 "$tmp" "$path"
  fi
  rm -f "$tmp"
}
safe_append() {
  local path="$1" tmp
  tmp="$(mktemp "$ROOT/append.XXXXXXXX")"
  cat > "$tmp"
  if [[ -w "$path" || ( ! -e "$path" && -w "$(dirname "$path")" ) ]]; then
    cat "$tmp" >> "$path"
  else
    need_sudo tee -a "$path" < "$tmp" >/dev/null
  fi
  rm -f "$tmp"
}
profile_init() {
  local line='for _bda in "$HOME"/.bda-lab-env.d/*.sh; do [ -f "$_bda" ] && . "$_bda"; done; unset _bda'
  touch "$HOME/.bashrc"
  grep -Fxq "$line" "$HOME/.bashrc" || printf '\n# BDA lab setup (Java / Hadoop / Hive / HBase / Sqoop)\n%s\n' "$line" >> "$HOME/.bashrc"
}
write_profile() {
  local name="$1"; shift
  profile_init
  printf '%s\n' "$@" > "$ENV_DIR/$name"
  # shellcheck disable=SC1090
  . "$ENV_DIR/$name"
}
find_hadoop() {
  local d
  for d in "${HADOOP_HOME:-}" "$HOME/hadoop-3.2.3" "$TOOLS/hadoop-3.2.3" /usr/local/hadoop; do
    [[ -n "$d" && -x "$d/bin/hdfs" && -f "$d/share/hadoop/common/hadoop-common-3.2.3.jar" ]] && { HADOOP_HOME="$(readlink -f "$d")"; export HADOOP_HOME; return 0; }
  done
  if command -v hadoop >/dev/null 2>&1; then
    d="$(dirname "$(dirname "$(readlink -f "$(command -v hadoop)")")")"
    [[ -f "$d/share/hadoop/common/hadoop-common-3.2.3.jar" ]] && { HADOOP_HOME="$d"; export HADOOP_HOME; return 0; }
  fi
  return 1
}
load_hadoop() {
  [[ -f "$ENV_DIR/10_hadoop.sh" ]] && . "$ENV_DIR/10_hadoop.sh"
  if ! find_hadoop; then
    local sibling="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/01_setup_hadoop.sh"
    [[ -f "$sibling" ]] || fail 'Hadoop 3.2.3 not found. Place 01_setup_hadoop.sh alongside this file and run it first.'
    note 'Hadoop 3.2.3 missing: installing via 01_setup_hadoop.sh'
    bash "$sibling"
    . "$ENV_DIR/10_hadoop.sh"
    find_hadoop || fail 'Hadoop installation did not become available.'
  fi
  ensure_java8
  export HADOOP_CONF_DIR="$HADOOP_HOME/etc/hadoop"
  export PATH="$JAVA_HOME/bin:$HADOOP_HOME/bin:$HADOOP_HOME/sbin:$PATH"
  export HADOOP_MAPRED_HOME="$HADOOP_HOME" HADOOP_COMMON_HOME="$HADOOP_HOME" HADOOP_HDFS_HOME="$HADOOP_HOME" HADOOP_YARN_HOME="$HADOOP_HOME"
  export HADOOP_CLASSPATH="${HADOOP_CLASSPATH:-}"
}
ensure_hdfs() {
  if ! timeout 18 "$HADOOP_HOME/bin/hdfs" dfs -ls / >/dev/null 2>&1; then
    note 'HDFS not responding; starting existing Hadoop services.'
    "$HADOOP_HOME/sbin/start-dfs.sh"
  fi
  local i
  for i in {1..30}; do
    timeout 10 "$HADOOP_HOME/bin/hdfs" dfs -ls / >/dev/null 2>&1 && return 0
    sleep 2
  done
  fail 'HDFS is not ready. Run 01_setup_hadoop.sh, then inspect ~/hadoop-3.2.3/logs.'
}

# 03 - HBase 2.4.18: HDFS-backed single-node HBase and Thrift.
note 'HBASE 2.4.18: install, configure, start HMaster / RegionServer / Thrift'
base_tools
load_hadoop
ensure_hdfs
require_cmd thrift thrift-compiler
HBASE_HOME=''
for d in "${BDA_HBASE_HOME:-}" "$HOME/hbase-2.4.18" "$TOOLS/hbase-2.4.18"; do
  if [[ -n "$d" && -f "$d/lib/hbase-common-2.4.18.jar" && -x "$d/bin/hbase" ]]; then HBASE_HOME="$(readlink -f "$d")"; break; fi
done
if [[ -z "$HBASE_HOME" ]] && command -v hbase >/dev/null 2>&1; then
  d="$(dirname "$(dirname "$(readlink -f "$(command -v hbase)")")")"
  [[ -f "$d/lib/hbase-common-2.4.18.jar" ]] && HBASE_HOME="$d"
fi
if [[ -z "$HBASE_HOME" ]]; then
  HBASE_HOME="$HOME/hbase-2.4.18"
  [[ ! -e "$HBASE_HOME" ]] || fail 'Incomplete HBase directory exists; refusing to overwrite it.'
  ARC="$CACHE/hbase-2.4.18-bin.tar.gz"
  archive_download "$ARC" \
    'https://repo.huaweicloud.com/apache/hbase/2.4.18/hbase-2.4.18-bin.tar.gz' \
    'https://mirrors.huaweicloud.com/apache/hbase/2.4.18/hbase-2.4.18-bin.tar.gz' \
    'https://archive.apache.org/dist/hbase/2.4.18/hbase-2.4.18-bin.tar.gz'
  archive_install "$ARC" hbase-2.4.18 "$HBASE_HOME"
fi
export HBASE_HOME PATH="$HBASE_HOME/bin:$PATH"
write_profile 30_hbase.sh "export HBASE_HOME='$HBASE_HOME'" 'export PATH="$HBASE_HOME/bin:$PATH"'
# HBase 2.4 was built with Hadoop 2 dependencies. It is compatible with Hadoop 3.2.x
# (HBase docs), but its bundled Hadoop client JARs can conflict in HDFS mode.
# Use the site's Hadoop classpath rather than disabling Hadoop classpath lookup.
if ! grep -q '^# BDA-HBASE' "$HBASE_HOME/conf/hbase-env.sh"; then
  backup "$HBASE_HOME/conf/hbase-env.sh"
  safe_append "$HBASE_HOME/conf/hbase-env.sh" <<ENV
# BDA-HBASE
export JAVA_HOME='$JAVA_HOME'
export HBASE_MANAGES_ZK=true
export HBASE_DISABLE_HADOOP_CLASSPATH_LOOKUP=false
ENV
fi
FS="$("$HADOOP_HOME/bin/hdfs" getconf -confKey fs.defaultFS)"
[[ "$FS" == hdfs://* ]] || fail "An HDFS filesystem is required for this experiment; detected: $FS"
ROOTDIR="${FS%/}/bda-hbase-2.4.18"
if [[ ! -f "$HBASE_HOME/conf/hbase-site.xml" ]] || ! grep -q '<name>hbase.rootdir</name>' "$HBASE_HOME/conf/hbase-site.xml"; then
  backup "$HBASE_HOME/conf/hbase-site.xml"
  mkdir -p "$ROOT/hbase-zk"
  safe_write "$HBASE_HOME/conf/hbase-site.xml" <<XML
<?xml version="1.0"?>
<configuration>
  <property><name>hbase.rootdir</name><value>$ROOTDIR</value></property>
  <property><name>hbase.cluster.distributed</name><value>true</value></property>
  <property><name>hbase.zookeeper.quorum</name><value>localhost</value></property>
  <property><name>hbase.zookeeper.property.clientPort</name><value>2181</value></property>
  <property><name>hbase.zookeeper.property.dataDir</name><value>$ROOT/hbase-zk</value></property>
  <property><name>zookeeper.znode.parent</name><value>/bda-hbase-2-4-18</value></property>
  <property><name>hbase.unsafe.stream.capability.enforce</name><value>false</value></property>
</configuration>
XML
else
  warn 'Existing HBase root directory setting found; preserving HBase configuration.'
fi
# Do not start a second HBase master against an existing different cluster.
if "$JAVA_HOME/bin/jps" | grep -qE '[[:space:]]HMaster($|[[:space:]])'; then
  note 'HMaster is already running; checking via this HBase client.'
else
  note 'Starting HBase services.'
  "$HBASE_HOME/bin/start-hbase.sh"
fi
READY=0
for i in {1..45}; do
  if "$JAVA_HOME/bin/jps" | grep -q HMaster && "$JAVA_HOME/bin/jps" | grep -q HRegionServer; then READY=1; break; fi
  sleep 2
done
(( READY )) || fail "HBase daemons did not start. Check $HBASE_HOME/logs"
note 'Testing HBase shell connection.'
if ! printf 'status "simple"\n' | timeout 100 "$HBASE_HOME/bin/hbase" shell -n ; then
  fail 'HBase status could not be read. Check configuration or conflicting HBase/ZooKeeper services.'
fi
if ! "$JAVA_HOME/bin/jps" | grep -q ThriftServer; then
  note 'Starting HBase Thrift server (port 9090).'
  "$HBASE_HOME/bin/hbase-daemon.sh" start thrift
fi
for i in {1..25}; do
  "$JAVA_HOME/bin/jps" | grep -q ThriftServer && break
  sleep 2
done
"$JAVA_HOME/bin/jps" | grep -q ThriftServer || fail 'Thrift did not start; inspect HBase logs/port 9090.'
"$JAVA_HOME/bin/jps"
note 'HBASE READY. New terminal: hbase shell; UI http://localhost:16010; Thrift TCP 9090'
