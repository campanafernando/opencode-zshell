# opencode-zshell

Zsh helpers for [OpenCode](https://opencode.ai) 2.2.7+ and
[FEFO](https://github.com/campanafernando/FEFO):

- **`fefo`** — calls the `opencode-fefo` plugin to run FEFO workspace commands.
- **`fefo-cli`** — calls the FEFO CLI directly when you do not need an OpenCode session.
- **`cmg`** — suggests a Conventional Commit message from the staged, unstaged, merge, rebase, or cherry-pick diff. It never commits; it prints the `git commit` command.
- **`doit`** — runs an arbitrary task through `opencode run`, in the current directory or a target directory.
- **`bng`** — suggests a branch name from the current diff and creates/checks out the branch.

## Requirements

- OpenCode **2.2.7+**
- zsh
- git
- python3
- coreutils `timeout` (Linux/WSL). macOS: `brew install coreutils`; the script aliases `timeout` to `gtimeout`.
- `node` is optional. `cmg`/`bng` use it to parse OpenCode JSON; without it they fall back to `sed`.
- `opencode-fefo` plugin for the `fefo` helper. `fefo-cli` works without it.

## Install

```sh
git clone https://github.com/campanafernando/opencode-zshell.git ~/opencode-zshell
```

Add this to `~/.zshrc`:

```zsh
source "${OPENCODE_ZSHELL:-$HOME/opencode-zshell}/opencode.zsh"
```

Reload the shell:

```sh
exec zsh
```

To keep the checkout somewhere else, export `OPENCODE_ZSHELL` before sourcing.

## Usage

### `fefo` — FEFO through the OpenCode plugin

```sh
fefo status
fefo add ../api --role api
fefo index api web
fefo doctor
```

By default `fefo` calls the `opencode-fefo` plugin through `opencode run`.
The plugin is published at
[`campanafernando/opencode-fefo`](https://github.com/campanafernando/opencode-fefo).
Until the npm package is published, load the checkout directly:

```jsonc
{
  "plugins": ["/absolute/path/to/opencode-fefo"]
}
```

After npm publication:

```sh
opencode plugin add opencode-fefo
```

The plugin needs the FEFO CLI in the workspace (`bin/fefo`), on `PATH`, or at
`FEFO_CLI`. The prompt asks the agent to call the `fefo_run` tool, so the
operation uses the same plugin surface as an interactive OpenCode session.

To bypass OpenCode and call the CLI directly:

```sh
FEFO_VIA=cli fefo status
# or
fefo-cli status
```

### `cmg` — commit message

```sh
git add .
cmg
# Suggested:
#   git commit -m "feat(auth): add password reset flow"
```

If nothing is staged, `cmg` uses the unstaged diff. It also understands merge, rebase, and cherry-pick states. The fallback message is used when the model is unavailable or returns something that is not a Conventional Commit.

### `doit` — task runner

```sh
doit "fix the failing tests and run the focused suite"
doit -C ~/projects/repo "update the deployment docs"
doit --ask "inspect this repo and suggest the next steps"
doit -i "open the task in the TUI"
```

Options:

```text
--ask, --safe          Use normal OpenCode permission prompts.
--allow, --auto-allow  Auto-approve permissions. Default.
-C, --dir DIR          Run from DIR instead of the current directory.
-m, --model MODEL      Override the model.
-i, --interactive      Open the TUI with the task instead of a scripted run.
```

`doit` auto-approves permissions by default (`opencode run --auto`). Use `--ask` when the task should stop for approval. The prompt tells the agent not to commit, amend, or push unless explicitly requested.

### `bng` — branch name

```sh
bng
# → feat/add-password-reset
```

It uses the staged diff when available, otherwise the unstaged diff, creates the branch, and checks it out.

## Model selection

By default, the helpers pick a free OpenCode Zen **text** model, excluding vision/omni/embedding models. The pick is cached for one hour at:

```text
${XDG_CACHE_HOME:-$HOME/.cache}/opencode/pick-model
```

Override per command:

```sh
CMG_MODEL=opencode-go/deepseek-v4.1-flash cmg
DOIT_MODEL=opencode/big-pickle doit "..."
BNG_MODEL=opencode/deepseek-v4.1-flash-free bng
```

Other environment variables:

| Variable | Default | Purpose |
| --- | --- | --- |
| `OPENCODE_MODEL_CACHE_TTL` | `3600` | Seconds before re-querying `opencode models`. |
| `OPENCODE_SESSION_CLEANUP_TTL` | `86400` | Seconds between session cleanups. |
| `CMG_TIMEOUT` | `120` | Seconds before `cmg` gives up on the model. |
| `BNG_TIMEOUT` | `120` | Seconds before `bng` gives up on the model. |
| `CMG_DIFF_LINES` | `400` | Diff lines attached to the `cmg` prompt. |
| `DOIT_MODEL` | auto | Default model for `doit`. |
| `DOIT_SKIP_PERMISSIONS` | `1` | Set to `0` to make `--ask` the default. |

Clear the cached pick after changing providers or model access:

```sh
rm -f "${XDG_CACHE_HOME:-$HOME/.cache}/opencode/pick-model"
```

## Sessions

`cmg`, `bng`, and `doit` create archived OpenCode sessions:

- `--archived` keeps them out of the TUI session list.
- `cmg` and `bng` prune their old sessions once per day.
- `doit` keeps the most recent session and prunes older ones once per day.

The cleanup stamp lives next to the model cache:

```text
${XDG_CACHE_HOME:-$HOME/.cache}/opencode/cleanup-cmg
${XDG_CACHE_HOME:-$HOME/.cache}/opencode/cleanup-doit
${XDG_CACHE_HOME:-$HOME/.cache}/opencode/cleanup-bng
```

## OpenCode 2.2.7 notes

These helpers use the current `opencode run` flags:

- `--archived` for scripted sessions.
- `--auto` instead of the old `--dangerously-skip-permissions`.
- `--format json` for `cmg`/`bng`.

They no longer use the removed/legacy V1 flags `--pure`, `--interactive`, or `--dir`. Directory changes are done with a subshell `cd`, and `doit -i` opens the TUI with the task prompt.

## Troubleshooting

**`cmg` prints the fallback message**

Check that OpenCode is authenticated and the selected model is available:

```sh
opencode auth list
opencode models | grep opencode/
```

Then clear the cached pick and retry.

**`opencode models` is slow**

The auto-pick is cached for an hour. Raise `OPENCODE_MODEL_CACHE_TTL` if the model list is stable, or set `CMG_MODEL` / `DOIT_MODEL` explicitly.

**`timeout: command not found`**

Install coreutils. On macOS, the script falls back to `gtimeout` when available.

## Files

- `opencode.zsh` — the sourceable helpers.
- `README.md` — this file.

## License

MIT. See [`LICENSE`](LICENSE).
