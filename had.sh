#!/usr/bin/env bash
# Ubuntu/Debian single-machine BDA practical setup. Run as your normal user.
# Requested primary Huawei download: https://repo.huaweicloud.com/apache/hadoop/common/hadoop-3.2.3/hadoop-3.2.3.tar.gz
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

# 01 - Hadoop 3.2.3: pseudo-distributed HDFS + YARN.
note 'HADOOP 3.2.3: install, configure, start, verify'
base_tools
require_cmd ssh openssh-client
require_cmd sshd openssh-server
ensure_java8
if find_hadoop; then
  note "Using existing Hadoop: $HADOOP_HOME"
else
  HADOOP_HOME="$HOME/hadoop-3.2.3"
  [[ ! -e "$HADOOP_HOME" ]] || fail "Incomplete or different installation exists at $HADOOP_HOME; preserve it and repair manually."
  ARC="$CACHE/hadoop-3.2.3.tar.gz"
  archive_download "$ARC" \
    'https://repo.huaweicloud.com/apache/hadoop/common/hadoop-3.2.3/hadoop-3.2.3.tar.gz' \
    'https://archive.apache.org/dist/hadoop/common/hadoop-3.2.3/hadoop-3.2.3.tar.gz'
  archive_install "$ARC" hadoop-3.2.3 "$HADOOP_HOME"
fi
[[ -x "$HADOOP_HOME/bin/hadoop" ]] || fail 'Hadoop installation files are incomplete.'
export HADOOP_CONF_DIR="$HADOOP_HOME/etc/hadoop" HADOOP_MAPRED_HOME="$HADOOP_HOME" HADOOP_COMMON_HOME="$HADOOP_HOME" HADOOP_HDFS_HOME="$HADOOP_HOME" HADOOP_YARN_HOME="$HADOOP_HOME"
export PATH="$JAVA_HOME/bin:$HADOOP_HOME/bin:$HADOOP_HOME/sbin:$PATH"
write_profile 10_hadoop.sh \
  "export JAVA_HOME='$JAVA_HOME'" \
  "export HADOOP_HOME='$HADOOP_HOME'" \
  'export HADOOP_CONF_DIR="$HADOOP_HOME/etc/hadoop"' \
  'export HADOOP_MAPRED_HOME="$HADOOP_HOME" HADOOP_COMMON_HOME="$HADOOP_HOME" HADOOP_HDFS_HOME="$HADOOP_HOME" HADOOP_YARN_HOME="$HADOOP_HOME"' \
  'export HADOOP_STREAMING="$HADOOP_HOME/share/hadoop/tools/lib/hadoop-streaming-3.2.3.jar"' \
  'export PDSH_RCMD_TYPE=ssh' \
  'export PATH="$JAVA_HOME/bin:$HADOOP_HOME/bin:$HADOOP_HOME/sbin:$PATH"'
# Keep existing active HDFS configs. Never replace a running cluster's settings.
FSDIR="$HOME/bda-hdfs-data"
FS="$("$HADOOP_HOME/bin/hdfs" getconf -confKey fs.defaultFS 2>/dev/null || true)"
if [[ "$FS" == hdfs://* ]]; then
  note "Existing HDFS configuration detected: $FS (preserving configurations and metadata)."
  MANAGED=0
else
  if "$JAVA_HOME/bin/jps" -l | grep -Eq 'org\.apache\.hadoop\.hdfs\.server\.namenode\.NameNode'; then
    fail 'NameNode is already running with a different configuration; refusing to reconfigure.'
  fi
  MANAGED=1
  mkdir -p "$FSDIR/name" "$FSDIR/data"
  for f in core-site.xml hdfs-site.xml mapred-site.xml yarn-site.xml; do backup "$HADOOP_CONF_DIR/$f"; done
  safe_write "$HADOOP_CONF_DIR/core-site.xml" <<'XML'
<?xml version="1.0"?>
<configuration>
  <property><name>fs.defaultFS</name><value>hdfs://localhost:9000</value></property>
</configuration>
XML
  safe_write "$HADOOP_CONF_DIR/hdfs-site.xml" <<XML
<?xml version="1.0"?>
<configuration>
  <property><name>dfs.replication</name><value>1</value></property>
  <property><name>dfs.namenode.name.dir</name><value>file://$FSDIR/name</value></property>
  <property><name>dfs.datanode.data.dir</name><value>file://$FSDIR/data</value></property>
</configuration>
XML
  safe_write "$HADOOP_CONF_DIR/mapred-site.xml" <<XML
<?xml version="1.0"?>
<configuration>
  <property><name>mapreduce.framework.name</name><value>yarn</value></property>
  <property><name>yarn.app.mapreduce.am.env</name><value>HADOOP_MAPRED_HOME=$HADOOP_HOME</value></property>
  <property><name>mapreduce.map.env</name><value>HADOOP_MAPRED_HOME=$HADOOP_HOME</value></property>
  <property><name>mapreduce.reduce.env</name><value>HADOOP_MAPRED_HOME=$HADOOP_HOME</value></property>
  <property><name>mapreduce.map.memory.mb</name><value>512</value></property>
  <property><name>mapreduce.reduce.memory.mb</name><value>512</value></property>
</configuration>
XML
  safe_write "$HADOOP_CONF_DIR/yarn-site.xml" <<'XML'
<?xml version="1.0"?>
<configuration>
  <property><name>yarn.nodemanager.aux-services</name><value>mapreduce_shuffle</value></property>
  <property><name>yarn.nodemanager.vmem-check-enabled</name><value>false</value></property>
  <property><name>yarn.nodemanager.resource.memory-mb</name><value>2048</value></property>
  <property><name>yarn.scheduler.minimum-allocation-mb</name><value>128</value></property>
  <property><name>yarn.nodemanager.env-whitelist</name><value>JAVA_HOME,HADOOP_HOME,HADOOP_MAPRED_HOME,HADOOP_HDFS_HOME,HADOOP_COMMON_HOME,HADOOP_YARN_HOME,HADOOP_CONF_DIR,PATH,LANG,TZ,CLASSPATH_PREPEND_DISTCACHE</value></property>
</configuration>
XML
fi
# Set JAVA_HOME in Hadoop's daemon environment only once (last export takes precedence).
if ! grep -q '^# BDA-JAVA8' "$HADOOP_CONF_DIR/hadoop-env.sh"; then
  backup "$HADOOP_CONF_DIR/hadoop-env.sh"
  printf '\n# BDA-JAVA8\nexport JAVA_HOME=%q\n' "$JAVA_HOME" | safe_append "$HADOOP_CONF_DIR/hadoop-env.sh"
fi
# Prepare local SSH; do not overwrite an existing identity.
mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
if [[ -f "$HOME/.ssh/id_ed25519.pub" ]]; then PUB="$HOME/.ssh/id_ed25519.pub"
elif [[ -f "$HOME/.ssh/id_rsa.pub" ]]; then PUB="$HOME/.ssh/id_rsa.pub"
else ssh-keygen -q -t ed25519 -N '' -f "$HOME/.ssh/id_ed25519"; PUB="$HOME/.ssh/id_ed25519.pub"; fi
PUBTEXT="$(cat "$PUB")"
touch "$HOME/.ssh/authorized_keys"; chmod 600 "$HOME/.ssh/authorized_keys"
grep -Fxq "$PUBTEXT" "$HOME/.ssh/authorized_keys" || printf '%s\n' "$PUBTEXT" >> "$HOME/.ssh/authorized_keys"
if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files ssh.service >/dev/null 2>&1; then
  need_sudo systemctl enable --now ssh || need_sudo service ssh start
else need_sudo service ssh start; fi
ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 localhost true || fail 'Passwordless localhost SSH failed.'
# Format only an empty NameNode directory created by this installer.
if (( MANAGED )); then
  if [[ ! -f "$FSDIR/name/current/VERSION" ]]; then
    [[ -z "$(ls -A "$FSDIR/name")" ]] || fail 'NameNode directory is nonempty and not recognized; will not format.'
    note 'First-time NameNode format (only once).'
    "$HADOOP_HOME/bin/hdfs" namenode -format -nonInteractive
  else note 'Existing NameNode metadata found; skipping format.'; fi
fi
if ! timeout 15 "$HADOOP_HOME/bin/hdfs" dfs -ls / >/dev/null 2>&1; then
  note 'Starting HDFS'; "$HADOOP_HOME/sbin/start-dfs.sh"
fi
ensure_hdfs
if ! "$JAVA_HOME/bin/jps" | grep -q 'ResourceManager'; then note 'Starting YARN'; "$HADOOP_HOME/sbin/start-yarn.sh"; fi
for i in {1..30}; do
  "$JAVA_HOME/bin/jps" | grep -q ResourceManager && "$JAVA_HOME/bin/jps" | grep -q NodeManager && break
  sleep 2
done
"$JAVA_HOME/bin/jps" | grep -q ResourceManager || fail 'YARN ResourceManager did not start.'
"$JAVA_HOME/bin/jps" | grep -q NodeManager || fail 'YARN NodeManager did not start.'
"$HADOOP_HOME/bin/hadoop" version | head -n 2
"$JAVA_HOME/bin/jps"
"$HADOOP_HOME/bin/hdfs" dfs -mkdir -p "/user/$(id -un)"
note 'HADOOP READY. HDFS UI: http://localhost:9870 | YARN UI: http://localhost:8088'
note 'New terminal: hadoop version; jps; hadoop fs -ls /'
