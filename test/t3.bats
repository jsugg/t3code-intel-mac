#!/usr/bin/env bats
# Exercises channel selection, the downgrade guard, rollback, and pass-through
# against a fake upstream with release tags. vp and node are stubs, so no network.

setup() {
  T3="$BATS_TEST_DIRNAME/../bin/t3"
  export HOME="$BATS_TEST_TMPDIR/home"
  export XDG_CONFIG_HOME="$HOME/.config" XDG_STATE_HOME="$HOME/.state" XDG_DATA_HOME="$HOME/.data"
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
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
  export PATH="$BATS_TEST_TMPDIR/stubs:$PATH"
  export T3_NODE="$BATS_TEST_TMPDIR/stubs/node"

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
