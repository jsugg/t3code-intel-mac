# t3code-intel-mac

[![CI](https://github.com/jsugg/t3code-intel-mac/actions/workflows/ci.yml/badge.svg)](https://github.com/jsugg/t3code-intel-mac/actions/workflows/ci.yml)

A `t3` command for [T3 Code](https://github.com/pingdotgg/t3code) on Intel Macs.

T3 Code doesn't ship a `t3` CLI for Intel Macs, and the reason is technical: the
CLI is a Node single-executable, and those segfault on darwin-x64
([`cliRelease.ts`](https://github.com/pingdotgg/t3code/blob/main/packages/shared/src/cliRelease.ts)).
Upstream's [Intel instructions](https://github.com/pingdotgg/t3code/blob/main/docs/user/install.md#intel-macs)
tell you to build from source and run `node apps/server/dist/bin.mjs` yourself.
That works, but then `t3 update` and `t3 service` don't.

This repo is one bash script that fills that gap. It keeps a source checkout,
builds it on the Node version upstream pins, and passes every other command
through to the real server CLI. It isn't affiliated with T3 Code. On Apple
Silicon or Linux, use the official `curl -fsSL https://t3.codes/install.sh | sh`.

## Requirements

- An Intel Mac. `uname -m` prints `x86_64`.
- `git` and `curl`. Both come with the Xcode Command Line Tools.
- About 5 GB for the checkout and its dependencies, plus about 650 MB for vp and Node.
- A provider CLI on your `PATH`, as described in upstream's
  [providers section](https://github.com/pingdotgg/t3code/blob/main/docs/user/install.md#providers).

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/jsugg/t3code-intel-mac/main/install.sh | bash
```

It's a short script. Read [`install.sh`](install.sh) first if you'd rather not
pipe a URL into bash, or clone this repo and run `./install.sh`.

The installer:

1. installs [vp](https://viteplus.dev) if it's missing, with Node management off so your
   `node`, nvm, or Homebrew setup stays as it is,
2. clones T3 Code into `~/.local/share/t3code-intel-mac/t3code`,
3. puts the wrapper at `~/.local/bin/t3`,
4. checks out the latest stable release and builds it (about 2 to 3 minutes).

| Variable     | Default                                   | Effect                                |
| ------------ | ----------------------------------------- | ------------------------------------- |
| `T3_REPO`    | `~/.local/share/t3code-intel-mac/t3code`  | Use an existing checkout or another path |
| `T3_CHANNEL` | `stable`                                  | `stable`, `nightly`, or `main`         |
| `T3_BIN_DIR` | `~/.local/bin`                            | Where `t3` goes                        |
| `T3_INTEL_FORCE` | unset                                 | Set to `1` to install on a machine that isn't an Intel Mac |

A non-default `T3_REPO` is saved to `~/.config/t3code-intel-mac/config`.

### Using a checkout you already built

If you followed upstream's Intel instructions, point the installer at that
checkout instead of cloning again. Pick the channel your build is on. A source
build of `main` is newer than any release, so `stable` or `nightly` would count
as a downgrade:

```bash
T3_REPO=~/path/to/t3code T3_CHANNEL=main ./install.sh
```

The checkout needs a clean working tree. The installer leaves your branch alone
apart from the update it runs.

## Use

```bash
t3                      # start the server for the current folder and open the web UI
t3 ~/code/my-project    # same, for another folder
t3 serve --port 3773    # any upstream command or flag works as usual
t3 wrapper              # list the commands this wrapper adds
```

| Command | What it does |
| --- | --- |
| `t3 update` | Fetch, check out the newest release on your channel, rebuild |
| `t3 update --channel nightly` | Switch channel. The choice sticks for later updates |
| `t3 update 0.1.9` | Pin one release without changing the channel |
| `t3 rebuild` | Reinstall dependencies and rebuild the current checkout |
| `t3 channel` | Show channel and version |
| `t3 service install` | Run the server as a launchd agent that starts at login |
| `t3 service status` / `restart` / `logs [-f]` / `uninstall` | Manage that agent |
| `t3 up`, `t3 connect` | Upstream remote access setup, applied to this wrapper's service |
| `t3 self-update` | Replace the wrapper with the latest version from this repo |
| `t3 uninstall` | Remove the wrapper, its service, and a default checkout |

### Channels

Upstream tags every release. `stable` is the newest `vX.Y.Z` tag, `nightly` is
the newest `vX.Y.Z-nightly.YYYYMMDD.N` tag, and `main` is the untested tip of
the main branch.

An older release can't read a database that a newer one already migrated.
`t3 update` refuses to go backwards (nightly to stable, for example) unless you
add `--allow-downgrade`.

If a build fails, the wrapper checks out the previous release again and
rebuilds it, so you keep a working server.

After a successful update, the wrapper asks before restarting the background
service, because a restart stops running agent turns and terminals. Pass
`--yes` to skip the question. A server you started by hand keeps running the
old build until you restart it.

### Background service

`t3 service install` writes `~/Library/LaunchAgents/io.github.jsugg.t3code-intel-mac.plist`.
The agent runs `t3 serve --no-browser` on `127.0.0.1:3773` and logs to
`~/Library/Logs/t3code-intel-mac/server.log`. It copies your current `PATH`
so the server can find provider CLIs, so run `t3 service install` again after
you install a new one.

It reads `~/.t3/service.env` the same way upstream's service does. Values are
literal `KEY=VALUE` with no shell expansion, and `PATH` and `T3CODE_HOME` are
ignored:

```dotenv
T3CODE_PORT=3773
T3CODE_HOST=127.0.0.1
```

### Remote access

`t3 up` and `t3 connect` run upstream's commands. They save your T3 Connect
sign-in and LAN choice, then try to install upstream's own background service.
That step always fails on Intel, because it downloads a darwin-x64 release
archive that doesn't exist. The wrapper recognizes that one error and offers to
restart its own service so the server picks up the new settings. Any other
failure keeps its exit code.

`t3 status` prints upstream's status, which always says "Service not installed"
on Intel, followed by the state of this wrapper's service.

## Uninstall

```bash
t3 uninstall
```

It lists what it will remove and asks once (`--yes` skips the question):
the background service, the wrapper, its state and config, and the checkout if
the installer cloned it to the default path. A checkout you pointed it at with
`T3_REPO` stays. So do `~/.t3` (projects, threads, and settings), vp, and Node.
Remove vp with `rm -rf ~/.local/share/vite-plus ~/.config/vite-plus`.

## Troubleshooting

**`vp not found`.** The wrapper looks in `~/.config/vite-plus/env`. Reinstall vp
with `curl -fsSL https://vite.plus | VP_NODE_MANAGER=no bash`.

**A build fails.** The wrapper restores the previous build, so `t3` still runs.
Build errors usually come from upstream. Run `t3 rebuild` to see the full output,
or wait for the next release and `t3 update` again.

**`local changes in ...`.** Something other than `pnpm-lock.yaml` changed in the
checkout. Check with `git -C "$(t3 repo)" status` and stash or discard it.

**Port 3773 is in use.** Another T3 Code server is running, maybe the desktop app
or a `t3 serve` in a terminal. Stop it, or set `T3CODE_PORT` in `~/.t3/service.env`
and run `t3 service restart`.

**The service can't find a provider CLI.** launchd doesn't load your shell
profile, so the agent uses the `PATH` saved at install time. Run
`t3 service install` again from a shell where the provider works.

**The service keeps restarting.** Read `t3 service logs`. launchd restarts the
agent after a crash and waits at least 10 seconds between attempts.

## How it works

- `bin/t3` reads the Node version from `engines.node` in T3 Code's `package.json`
  and asks vp for that exact version. vp downloads it once into its own store. The
  path is cached in `~/.local/state/t3code-intel-mac`.
- Builds run `vp i && vp run build:desktop`, as upstream documents.
- Wrapper state lives in the checkout's git config: `t3.channel`, and
  `t3.built` for the last successful build.
- `vp i` rewrites `pnpm-lock.yaml` on every build, so the wrapper resets that
  file before an update. Any other local change stops the update.

## Development

```bash
shellcheck bin/t3 install.sh
bats test/
```

The tests run against a fake upstream with release tags and stub `vp` and
`node`, so they don't need network access or a real build. CI also runs a
weekly install and boot check on an Intel macOS runner.

## License

MIT. T3 Code is a separate project with its own license.
