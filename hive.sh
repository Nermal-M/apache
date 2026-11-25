#!/usr/bin/env bash
# Ubuntu/Debian single-machine BDA practical setup. Run as your normal user.
# Requested primary Huawei download: https://mirrors.huaweicloud.com/repository/apache/hive/hive-3.1.2/apache-hive-3.1.2-bin.tar.gz
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

# 02 - Hive 3.1.2: local Derby metastore; CLI available for manual practice.
note 'HIVE 3.1.2: install, configure, initialize metastore, verify'
base_tools
load_hadoop
ensure_hdfs
HIVE_HOME=''
for d in "${BDA_HIVE_HOME:-}" "$HOME/apache-hive-3.1.2-bin" "$TOOLS/apache-hive-3.1.2-bin"; do
  if [[ -n "$d" && -f "$d/lib/hive-common-3.1.2.jar" && -x "$d/bin/hive" ]]; then HIVE_HOME="$(readlink -f "$d")"; break; fi
done
if [[ -z "$HIVE_HOME" ]] && command -v hive >/dev/null 2>&1; then
  d="$(dirname "$(dirname "$(readlink -f "$(command -v hive)")")")"
  [[ -f "$d/lib/hive-common-3.1.2.jar" ]] && HIVE_HOME="$d"
fi
if [[ -z "$HIVE_HOME" ]]; then
  HIVE_HOME="$HOME/apache-hive-3.1.2-bin"
  [[ ! -e "$HIVE_HOME" ]] || fail 'Incomplete Hive directory already exists; not replacing it.'
  ARC="$CACHE/apache-hive-3.1.2-bin.tar.gz"
  archive_download "$ARC" \
    'https://mirrors.huaweicloud.com/repository/apache/hive/hive-3.1.2/apache-hive-3.1.2-bin.tar.gz' \
    'https://repo.huaweicloud.com/apache/hive/hive-3.1.2/apache-hive-3.1.2-bin.tar.gz' \
    'https://archive.apache.org/dist/hive/hive-3.1.2/apache-hive-3.1.2-bin.tar.gz'
  archive_install "$ARC" apache-hive-3.1.2-bin "$HIVE_HOME"
fi
export HIVE_HOME PATH="$HIVE_HOME/bin:$PATH"
write_profile 20_hive.sh "export HIVE_HOME='$HIVE_HOME'" 'export PATH="$HIVE_HOME/bin:$PATH"'
# Hive 3.1.2 bundles Guava 19; Hadoop 3.2.3 uses Guava 27. Match Hadoop to avoid NoSuchMethodError.
shopt -s nullglob
HGUAVAS=( "$HADOOP_HOME"/share/hadoop/common/lib/guava-*.jar )
((${#HGUAVAS[@]}==1)) || fail 'Expected exactly one Hadoop Guava JAR; inspect Hadoop installation.'
for jar in "$HIVE_HOME"/lib/guava-*.jar; do
  if [[ "$(basename "$jar")" != "$(basename "${HGUAVAS[0]}")" ]]; then
    backup "$jar"; if [[ -w "$jar" ]]; then rm -f "$jar"; else need_sudo rm -f "$jar"; fi
  fi
done
if [[ ! -f "$HIVE_HOME/lib/$(basename "${HGUAVAS[0]}")" ]]; then
  if [[ -w "$HIVE_HOME/lib" ]]; then cp "${HGUAVAS[0]}" "$HIVE_HOME/lib/"; else need_sudo cp "${HGUAVAS[0]}" "$HIVE_HOME/lib/"; fi
fi
shopt -u nullglob
# Initialize a new Derby metastore in a stable, absolute location; never reset existing data.
METASTORE="$ROOT/hive/metastore_db"
mkdir -p "$ROOT/hive"
if [[ ! -f "$HIVE_HOME/conf/hive-site.xml" ]] || ! grep -q 'javax.jdo.option.ConnectionURL' "$HIVE_HOME/conf/hive-site.xml"; then
  backup "$HIVE_HOME/conf/hive-site.xml"
  safe_write "$HIVE_HOME/conf/hive-site.xml" <<XML
<?xml version="1.0"?>
<configuration>
  <property><name>javax.jdo.option.ConnectionURL</name><value>jdbc:derby:;databaseName=$METASTORE;create=true</value></property>
  <property><name>javax.jdo.option.ConnectionDriverName</name><value>org.apache.derby.jdbc.EmbeddedDriver</value></property>
  <property><name>hive.metastore.warehouse.dir</name><value>/user/hive/warehouse</value></property>
  <property><name>hive.metastore.schema.verification</name><value>true</value></property>
</configuration>
XML
else
  warn 'Existing Hive metastore settings found; retaining your hive-site.xml.'
fi
"$HADOOP_HOME/bin/hdfs" dfs -mkdir -p /tmp /user/hive/warehouse
"$HADOOP_HOME/bin/hdfs" dfs -chmod 1777 /tmp || warn 'Could not change /tmp permissions (may belong to an administrator).'
"$HADOOP_HOME/bin/hdfs" dfs -chmod 775 /user/hive/warehouse || warn 'Could not change warehouse permissions.'
if "$HIVE_HOME/bin/schematool" -dbType derby -info >/dev/null 2>&1; then
  note 'Hive schema is already initialized; preserving it.'
else
  [[ ! -e "$METASTORE" ]] || fail "Hive metastore exists but schema check failed ($METASTORE). Not deleting it. Inspect the Derby logs."
  note 'Initializing new Hive Derby schema once.'
  "$HIVE_HOME/bin/schematool" -dbType derby -initSchema
fi
"$HIVE_HOME/bin/schematool" -dbType derby -info || fail 'Hive metastore validation failed.'
note 'Hive CLI smoke test: SHOW DATABASES;'
if ! timeout 180 "$HIVE_HOME/bin/hive" -e 'SHOW DATABASES;' ; then
  fail 'Hive CLI did not pass its smoke test. Inspect the log; existing metastore is preserved.'
fi
note 'HIVE READY. New terminal: hive  (then SHOW DATABASES; or CREATE DATABASE mydb;)'
