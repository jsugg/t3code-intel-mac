#!/usr/bin/env bats
# Exercises channel selection, the downgrade guard, rollback, and pass-through
# against a fake upstream with release tags. vp and node are stubs, so no network.

setup() {
  T3="$BATS_TEST_DIRNAME/../bin/t3"
  export HOME="$BATS_TEST_TMPDIR/home"
  export XDG_CONFIG_HOME="$HOME/.config" XDG_STATE_HOME="$HOME/.state" XDG_DATA_HOME="$HOME/.data"
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  # launchd labels are per user, not per HOME; never touch a real install's agent.
  export T3_SERVICE_LABEL="test.t3code-intel-mac.$$"
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
  mkdir -p "$HOME" "$BATS_TEST_TMPDIR/stubs"

  stub vp <<'EOF'
case "$1" in
  i) echo "rewritten" >>pnpm-lock.yaml ;;
  run)
    [ -f FAIL_BUILD ] && { echo "stub build failure" >&2; exit 1; }
    mkdir -p apps/server/dist
    echo "// built" >apps/server/dist/bin.mjs
    ;;
  *) echo "unexpected vp $*" >&2; exit 2 ;;
esac
EOF
  stub node <<'EOF'
case "$1" in
  --version) echo v26.12.1 ;;
  *) echo "node $*" ;;
esac
EOF
  # launchctl keeps loaded agents as files, so service paths run on any OS.
  stub launchctl <<'EOF'
state="$HOME/.launchctl"
mkdir -p "$state"
case "$1" in
  print)
    [ -f "$state/${2##*/}" ] || exit 113
    printf '\tstate = running\n\tpid = 4242\n'
    ;;
  bootstrap)
    label="$(sed -n 's|.*<key>Label</key><string>\(.*\)</string>.*|\1|p' "$3")"
    cp "$3" "$state/$label"
    ;;
  bootout) rm -f "$state/${2##*/}" ;;
  kickstart) echo "kickstart ${3##*/}" >>"$state/log" ;;
  *) echo "unexpected launchctl $*" >&2; exit 2 ;;
esac
EOF
  stub plutil <<'EOF'
exit 0
EOF
  stub uname <<'EOF'
case "$1" in -m) echo x86_64 ;; *) echo Darwin ;; esac
EOF
  export PATH="$BATS_TEST_TMPDIR/stubs:$PATH"
  export T3_NODE="$BATS_TEST_TMPDIR/stubs/node"
  export T3_NONINTERACTIVE=1

  make_upstream
  export T3_REPO="$BATS_TEST_TMPDIR/t3code"
  git clone -q "$UPSTREAM" "$T3_REPO"
}

stub() {
  { echo '#!/bin/bash'; cat; } >"$BATS_TEST_TMPDIR/stubs/$1"
  chmod +x "$BATS_TEST_TMPDIR/stubs/$1"
}

commit_tag() {
  echo "$1" >>history
  git add -A
  git commit -qm "$1"
  [ -z "${2:-}" ] || git tag "$2"
}

# History on main: v0.1.0 < two nightlies < v0.1.1 < same-day nightlies .9 and .11 < untagged tip.
# A side preview build (matched by no channel) fails to build.
make_upstream() {
  UPSTREAM="$BATS_TEST_TMPDIR/upstream"
  git init -q -b main "$UPSTREAM"
  (
  cd "$UPSTREAM" || exit 1
  printf '{\n  "engines": {\n    "node": "26.12.1"\n  }\n}\n' >package.json
  echo "lock" >pnpm-lock.yaml
  echo "apps/server/dist/" >.gitignore
  commit_tag c1 v0.1.0
  commit_tag c2 v0.1.1-nightly.20261109.9
  commit_tag c3 v0.1.1-nightly.20261110.10
  commit_tag c4 v0.1.1
  git tag mobile-android-build/9.9.9/deadbeef
  commit_tag c5 v0.1.2-nightly.20261111.9
  commit_tag c5b v0.1.2-nightly.20261111.11
  commit_tag c6
  git checkout -q -b broken
  touch FAIL_BUILD
  commit_tag broken v0.1.3-preview.20261112.1
  git checkout -q main
  git branch -q -D broken
  )
}

head_tag() { git -C "$T3_REPO" describe --tags --exact-match --exclude 'mobile-*' 2>/dev/null || git -C "$T3_REPO" rev-parse --short HEAD; }

@test "stable picks the highest plain vX.Y.Z tag" {
  run "$T3" update --channel stable --yes
  [ "$status" -eq 0 ]
  [ "$(head_tag)" = v0.1.1 ]
  [ "$(git -C "$T3_REPO" config t3.channel)" = stable ]
  [ -f "$T3_REPO/apps/server/dist/bin.mjs" ]
}

@test "nightly sorts by version, not text" {
  run "$T3" update --channel nightly --yes
  [ "$status" -eq 0 ]
  [ "$(head_tag)" = v0.1.2-nightly.20261111.11 ]
}

@test "channel sticks across updates" {
  "$T3" update --channel=nightly --yes
  run "$T3" update --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"already on nightly"* ]]
}

@test "main follows the untagged tip on the main branch" {
  run "$T3" update --channel main --yes
  [ "$status" -eq 0 ]
  [ "$(git -C "$T3_REPO" symbolic-ref --short HEAD)" = main ]
  [ "$(git -C "$T3_REPO" log -1 --format=%s)" = c6 ]
}

@test "moving to an older release needs --allow-downgrade" {
  "$T3" update --channel nightly --yes
  run "$T3" update --channel stable --yes
  [ "$status" -ne 0 ]
  [[ "$output" == *"--allow-downgrade"* ]]
  [ "$(head_tag)" = v0.1.2-nightly.20261111.11 ]

  run "$T3" update --channel stable --allow-downgrade --yes
  [ "$status" -eq 0 ]
  [ "$(head_tag)" = v0.1.1 ]
}

@test "an untracked first build may go anywhere" {
  run "$T3" update 0.1.0 --yes
  [ "$status" -eq 0 ]
  [ "$(head_tag)" = v0.1.0 ]
}

@test "pinning a version leaves the channel alone" {
  "$T3" update --channel stable --yes
  run "$T3" update v0.1.2-nightly.20261111.11 --yes
  [ "$status" -eq 0 ]
  [ "$(head_tag)" = v0.1.2-nightly.20261111.11 ]
  [ "$(git -C "$T3_REPO" config t3.channel)" = stable ]
}

@test "unknown version and channel fail clearly" {
  run "$T3" update 7.7.7 --yes
  [ "$status" -ne 0 ]
  [[ "$output" == *"no release tag v7.7.7"* ]]
  run "$T3" update --channel beta --yes
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown channel 'beta'"* ]]
}

@test "a failed build restores the previous release and its build" {
  "$T3" update --channel stable --yes
  run "$T3" update 0.1.3-preview.20261112.1 --yes
  [ "$status" -ne 0 ]
  [[ "$output" == *"restoring"* ]]
  [ "$(head_tag)" = v0.1.1 ]
  [ -f "$T3_REPO/apps/server/dist/bin.mjs" ]
  [ "$(git -C "$T3_REPO" config t3.built)" = "$(git -C "$T3_REPO" rev-parse v0.1.1)" ]
}

@test "a failed build on main moves the branch back" {
  "$T3" update --channel main --yes
  good="$(git -C "$T3_REPO" rev-parse HEAD)"
  (cd "$UPSTREAM" && touch FAIL_BUILD && commit_tag c7)
  run "$T3" update --yes
  [ "$status" -ne 0 ]
  [ "$(git -C "$T3_REPO" symbolic-ref --short HEAD)" = main ]
  [ "$(git -C "$T3_REPO" rev-parse main)" = "$good" ]
  [ "$(git -C "$T3_REPO" config t3.built)" = "$good" ]
}

@test "local edits block an update; the lockfile rewrite does not" {
  "$T3" update --channel stable --yes
  [ -n "$(git -C "$T3_REPO" status --porcelain pnpm-lock.yaml)" ]
  echo edit >>"$T3_REPO/package.json"
  run "$T3" update --channel nightly --yes
  [ "$status" -ne 0 ]
  [[ "$output" == *"local changes"* ]]

  git -C "$T3_REPO" checkout -q -- package.json
  run "$T3" update --channel nightly --yes
  [ "$status" -eq 0 ]
}

@test "other commands run the server with the pinned node" {
  "$T3" update --channel stable --yes
  run "$T3" serve --no-browser --port 1234
  [ "$status" -eq 0 ]
  [ "$output" = "node $T3_REPO/apps/server/dist/bin.mjs serve --no-browser --port 1234" ]
}

@test "running before a build says how to fix it" {
  run "$T3" --version
  [ "$status" -ne 0 ]
  [[ "$output" == *"t3 rebuild"* ]]
}

@test "T3_REPO can come from the config file" {
  mkdir -p "$XDG_CONFIG_HOME/t3code-intel-mac"
  echo "T3_REPO=\"$T3_REPO\"" >"$XDG_CONFIG_HOME/t3code-intel-mac/config"
  run env -u T3_REPO "$T3" repo
  [ "$output" = "$T3_REPO" ]
}

@test "service.env is read literally and cannot override PATH" {
  "$T3" update --channel stable --yes
  mkdir -p "$HOME/.t3"
  # shellcheck disable=SC2016
  printf '%s\n' '# comment' 'T3CODE_PORT=3999' 'GREETING="hello $USER"' 'PATH=/nowhere' >"$HOME/.t3/service.env"
  stub node <<'EOF'
echo "port=$T3CODE_PORT greeting=$GREETING path_ok=$([ "$PATH" != /nowhere ] && echo yes) args=$*"
EOF
  run "$T3" __service-run
  [ "$status" -eq 0 ]
  # shellcheck disable=SC2016
  [[ "$output" == *'port=3999 greeting=hello $USER path_ok=yes'* ]]
  [[ "$output" == *"serve --no-browser"* ]]
}

@test "wrapper help lists the added commands" {
  run "$T3" wrapper
  [ "$status" -eq 0 ]
  [[ "$output" == *"t3 update"* ]]
  [[ "$output" == *"t3 service install"* ]]
}

# Stub node acting as upstream `t3 up`: writes service.env, then fails like the
# darwin-x64 service install does unless STUB_UP_OK is set.
stub_upstream_up() {
  stub node <<'EOF2'
home="$HOME/.t3"
prev=""
for a in "$@"; do [ "$prev" = --base-dir ] && home="$a"; prev="$a"; done
mkdir -p "$home"
[ -z "${STUB_LAN:-}" ] || echo "T3CODE_LAN=$STUB_LAN" >"$home/service.env"
[ -n "${STUB_UP_OK:-}" ] && exit 0
echo "ERROR: Background setup failed while selecting a t3 release archive for darwin-x64."
exit 1
EOF2
}

plist() { echo "$HOME/Library/LaunchAgents/$T3_SERVICE_LABEL.plist"; }
kicks() { cat "$HOME/.launchctl/log" 2>/dev/null | grep -c kickstart || true; }

@test "t3 up installs the wrapper's service where upstream would install its own" {
  "$T3" update --channel stable --yes
  stub_upstream_up
  STUB_LAN=true run "$T3" up --lan
  [ "$status" -eq 0 ]
  [[ "$output" == *"ignore the darwin-x64 error above"* ]]
  [[ "$output" == *"service installed"* ]]
  [ -f "$HOME/.launchctl/$T3_SERVICE_LABEL" ]
  grep -q "<key>T3_REPO</key><string>$T3_REPO</string>" "$(plist)"
  grep -q "__service-run" "$(plist)"
}

@test "t3 up restarts a running service when the settings change" {
  "$T3" update --channel stable --yes
  "$T3" service install
  stub_upstream_up
  STUB_LAN=false STUB_UP_OK=1 run "$T3" up --no-lan
  [ "$status" -eq 0 ]
  [[ "$output" == *"service restarted"* ]]
  [ "$(kicks)" -eq 1 ]
}

@test "t3 up with no change leaves the service alone" {
  "$T3" update --channel stable --yes
  "$T3" service install
  stub_upstream_up
  STUB_UP_OK=1 run "$T3" up --no-lan
  [ "$status" -eq 0 ]
  [ "$(kicks)" -eq 0 ]
}

@test "t3 up for another T3 home doesn't touch a service serving ~/.t3" {
  "$T3" update --channel stable --yes
  "$T3" service install
  stub_upstream_up
  STUB_LAN=true run "$T3" up --lan --base-dir "$BATS_TEST_TMPDIR/other"
  [ "$status" -eq 0 ]
  [[ "$output" == *"left alone"* ]]
  [ "$(kicks)" -eq 0 ]
}

@test "a service installed for a custom T3 home records it" {
  "$T3" update --channel stable --yes
  mkdir -p "$BATS_TEST_TMPDIR/home2"
  T3CODE_HOME="$BATS_TEST_TMPDIR/home2" run "$T3" service install
  [ "$status" -eq 0 ]
  grep -q "<key>T3CODE_HOME</key><string>$(cd "$BATS_TEST_TMPDIR/home2" && pwd -P)</string>" "$(plist)"
}

@test "service uninstall unloads the agent and removes its plist" {
  "$T3" update --channel stable --yes
  "$T3" service install
  run "$T3" service uninstall
  [ "$status" -eq 0 ]
  [ ! -f "$(plist)" ]
  [ ! -f "$HOME/.launchctl/$T3_SERVICE_LABEL" ]
}

@test "t3 status adds the wrapper's service to upstream's report" {
  "$T3" update --channel stable --yes
  "$T3" service install
  stub node <<'EOF2'
echo "This machine"
EOF2
  run "$T3" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"Intel Mac service (t3 service): running · pid 4242"* ]]
}

@test "other t3 up failures keep their exit code" {
  "$T3" update --channel stable --yes
  stub node <<'EOF2'
echo "something else broke"
exit 3
EOF2
  run "$T3" up --lan
  [ "$status" -eq 3 ]
  [[ "$output" != *"darwin-x64"* ]]
}

@test "t3 status --json is passed through untouched" {
  "$T3" update --channel stable --yes
  stub node <<'EOF2'
echo '{"service":{}}'
EOF2
  run "$T3" status --json
  [ "$status" -eq 0 ]
  [ "$output" = '{"service":{}}' ]
}

# self-update rewrites the running file, so these work on a copy of the wrapper.
self_update_setup() {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cp "$T3" "$BATS_TEST_TMPDIR/bin/t3"
  stub curl <<'EOF2'
out=""
prev=""
for a in "$@"; do [ "$prev" = -o ] && out="$a"; prev="$a"; done
cp "$STUB_DOWNLOAD" "$out"
EOF2
}

@test "self-update with nothing new leaves no temp file behind" {
  self_update_setup
  STUB_DOWNLOAD="$BATS_TEST_TMPDIR/bin/t3" run "$BATS_TEST_TMPDIR/bin/t3" self-update
  [ "$status" -eq 0 ]
  [[ "$output" == *"already up to date"* ]]
  [[ "$output" != *"unbound"* ]]
  [ "$(ls "$BATS_TEST_TMPDIR/bin")" = t3 ]
}

@test "self-update replaces the wrapper with a newer version" {
  self_update_setup
  sed 's/^T3_WRAPPER_VERSION=.*/T3_WRAPPER_VERSION="9.9.9"/' "$T3" >"$BATS_TEST_TMPDIR/new"
  STUB_DOWNLOAD="$BATS_TEST_TMPDIR/new" run "$BATS_TEST_TMPDIR/bin/t3" self-update
  [ "$status" -eq 0 ]
  [[ "$output" == *"updated to 9.9.9"* ]]
  [ -x "$BATS_TEST_TMPDIR/bin/t3" ]
  [ "$(ls "$BATS_TEST_TMPDIR/bin")" = t3 ]
}

@test "self-update refuses a download that doesn't parse" {
  self_update_setup
  echo 'if then fi (' >"$BATS_TEST_TMPDIR/broken"
  STUB_DOWNLOAD="$BATS_TEST_TMPDIR/broken" run "$BATS_TEST_TMPDIR/bin/t3" self-update
  [ "$status" -ne 0 ]
  cmp -s "$T3" "$BATS_TEST_TMPDIR/bin/t3"
  [ "$(ls "$BATS_TEST_TMPDIR/bin")" = t3 ]
}
