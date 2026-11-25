#!/usr/bin/env bash
# Ubuntu/Debian single-machine BDA practical setup. Run as your normal user.
# Sqoop 1.4.7 source kept as in lab manual; no Huawei URL specified.
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

# 04 - Apache Sqoop 1.4.7 + MySQL: installation/configuration only.
note 'SQOOP 1.4.7: install Sqoop, MySQL, JDBC dependencies, verify connection'
base_tools
load_hadoop
ensure_hdfs
if ! command -v mysql >/dev/null 2>&1 || ! command -v mysqld >/dev/null 2>&1; then install_pkgs mysql-server; fi
if ! mysqladmin ping >/dev/null 2>&1; then
  if command -v systemctl >/dev/null 2>&1; then
    need_sudo systemctl start mysql || need_sudo service mysql start
  else need_sudo service mysql start; fi
fi
mysqladmin ping >/dev/null 2>&1 || fail 'MySQL server did not start.'
need_sudo mysql -N -e 'SELECT 1;' >/dev/null || fail 'sudo mysql administrative login failed. Configure local MySQL admin account.'
SQOOP_HOME=''
for d in "${BDA_SQOOP_HOME:-}" "$HOME/sqoop-1.4.7.bin__hadoop-2.6.0" "$TOOLS/sqoop-1.4.7.bin__hadoop-2.6.0" /usr/local/sqoop; do
  if [[ -n "$d" && -x "$d/bin/sqoop" && -f "$d/sqoop-1.4.7.jar" ]]; then SQOOP_HOME="$(readlink -f "$d")"; break; fi
done
if [[ -z "$SQOOP_HOME" ]] && command -v sqoop >/dev/null 2>&1; then
  d="$(dirname "$(dirname "$(readlink -f "$(command -v sqoop)")")")"
  [[ -f "$d/sqoop-1.4.7.jar" ]] && SQOOP_HOME="$d"
fi
if [[ -z "$SQOOP_HOME" ]]; then
  SQOOP_HOME="$HOME/sqoop-1.4.7.bin__hadoop-2.6.0"
  [[ ! -e "$SQOOP_HOME" ]] || fail 'Incomplete Sqoop directory exists; refusing to overwrite it.'
  ARC="$CACHE/sqoop-1.4.7.bin__hadoop-2.6.0.tar.gz"
  archive_download "$ARC" \
    'https://archive.apache.org/dist/sqoop/1.4.7/sqoop-1.4.7.bin__hadoop-2.6.0.tar.gz'
  archive_install "$ARC" sqoop-1.4.7.bin__hadoop-2.6.0 "$SQOOP_HOME"
fi
export SQOOP_HOME PATH="$SQOOP_HOME/bin:$PATH"
write_profile 40_sqoop.sh "export SQOOP_HOME='$SQOOP_HOME'" 'export PATH="$SQOOP_HOME/bin:$PATH"'
if [[ ! -f "$SQOOP_HOME/conf/sqoop-env.sh" ]]; then
  if [[ -w "$SQOOP_HOME/conf" ]]; then cp "$SQOOP_HOME/conf/sqoop-env-template.sh" "$SQOOP_HOME/conf/sqoop-env.sh"; else need_sudo cp "$SQOOP_HOME/conf/sqoop-env-template.sh" "$SQOOP_HOME/conf/sqoop-env.sh"; fi
fi
if ! grep -q '^# BDA-SQOOP' "$SQOOP_HOME/conf/sqoop-env.sh"; then
  backup "$SQOOP_HOME/conf/sqoop-env.sh"
  safe_append "$SQOOP_HOME/conf/sqoop-env.sh" <<ENV
# BDA-SQOOP
export HADOOP_COMMON_HOME='$HADOOP_HOME'
export HADOOP_MAPRED_HOME='$HADOOP_HOME'
ENV
fi
require_cmd jar openjdk-8-jdk
JAR_DIR="$SQOOP_HOME/lib"
download_jar() {
  local file="$1" url="$2" dest="$JAR_DIR/$1"
  if [[ -s "$dest" ]] && jar tf "$dest" >/dev/null 2>&1; then return 0; fi
  [[ ! -e "$dest" ]] || backup "$dest"
  note "Downloading missing JDBC/commons dependency: $file"
  curl -fL --retry 3 --connect-timeout 20 --output "$CACHE/$file.part" "$url"
  jar tf "$CACHE/$file.part" >/dev/null 2>&1 || fail "Invalid JAR: $file"
  if [[ -w "$JAR_DIR" ]]; then install -m 0644 "$CACHE/$file.part" "$dest"; else need_sudo install -m 0644 "$CACHE/$file.part" "$dest"; fi
  rm -f "$CACHE/$file.part"
}
download_jar mysql-connector-j-8.0.33.jar \
  https://repo.maven.apache.org/maven2/com/mysql/mysql-connector-j/8.0.33/mysql-connector-j-8.0.33.jar
download_jar commons-lang-2.6.jar \
  https://repo.maven.apache.org/maven2/commons-lang/commons-lang/2.6/commons-lang-2.6.jar
# Local lab-only credentials from the uploaded manual. Existing other DBs/tables remain unchanged.
DB='company'; DB_USER='sqoopuser'; DB_PASS="${BDA_SQOOP_LAB_PASSWORD:-sqoop123}"
[[ "$DB_PASS" =~ ^[A-Za-z0-9_@%+=.-]{6,64}$ ]] || fail 'BDA_SQOOP_LAB_PASSWORD must be 6-64 safe password characters.'
need_sudo mysql <<SQL
CREATE DATABASE IF NOT EXISTS company;
CREATE USER IF NOT EXISTS 'sqoopuser'@'localhost' IDENTIFIED BY '$DB_PASS';
CREATE USER IF NOT EXISTS 'sqoopuser'@'127.0.0.1' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON company.* TO 'sqoopuser'@'localhost';
GRANT ALL PRIVILEGES ON company.* TO 'sqoopuser'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL
# Important: never ALTER an existing user's password; avoid clobbering someone else's MySQL login.
PASSWORD_FILE="$ROOT/sqoop/mysql-password.txt"
mkdir -p "$(dirname "$PASSWORD_FILE")"
(umask 077; printf '%s\n' "$DB_PASS" > "$PASSWORD_FILE")
# mysql --defaults-extra-file or MYSQL_PWD from this script is used only for validation.
MYSQL_PWD="$DB_PASS" mysql -h 127.0.0.1 -u "$DB_USER" -N -e 'SELECT DATABASE();' "$DB" >/dev/null || \
  fail 'MySQL sqoopuser login failed (possibly pre-existing account with different password). Account was NOT overwritten.'
"$SQOOP_HOME/bin/sqoop" version
note 'Sqoop JDBC connection test (does not import/export any data).'
CONNECT='jdbc:mysql://127.0.0.1:3306/company?useSSL=false&allowPublicKeyRetrieval=true'
timeout 120 "$SQOOP_HOME/bin/sqoop" list-tables \
  --connect "$CONNECT" --username "$DB_USER" \
  --password-file "file://$PASSWORD_FILE" || fail 'Sqoop JDBC connection failed. Inspect the Java output; no data was imported/exported.'
note 'SQOOP READY. MySQL database: company; user: sqoopuser; credentials: ~/.bda-lab-setup/sqoop/mysql-password.txt'
note 'Next: create employees and employees_exported manually using the lab PDF, then run Sqoop import/export commands.'
