# OpenCode zsh helpers: cmg, doit, bng.
# Requires OpenCode 2.2.7+. Source this file from ~/.zshrc.
#
# Usage:
#   source "${OPENCODE_ZSHELL:-$HOME/opencode-zshell}/opencode.zsh"

# macOS: coreutils timeout is gtimeout. Aliases expand when functions are defined.
if ! command -v timeout >/dev/null 2>&1 && command -v gtimeout >/dev/null 2>&1; then
  alias timeout=gtimeout
fi

# ---- Commit message generator ----
# Re-sourcing guard: zsh expands aliases before function definitions.
unalias cmg 2>/dev/null
unalias doit 2>/dev/null

# Free Zen models rotate (deepseek-v4-flash-free came and went). The auto-pick
# is cached for an hour so cmg/doit/bng do not pay `opencode models` every time.
# An explicit *_MODEL is returned as-is; invalid values fail at opencode run.
# Trade-off: `opencode models` is the only liveness source; it hangs if the repo
# ships a plugin, so the call is timeout-guarded and degrades to the models.dev
# cache ranking (which may list retired models) when it does.
_opencode_mtime() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0
}

_opencode_session_cleanup() {
  local title="$1" keep="${2:-0}"
  local cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/opencode"
  local stamp="$cache_dir/cleanup-$title"
  local ttl="${OPENCODE_SESSION_CLEANUP_TTL:-86400}"
  mkdir -p "$cache_dir"
  if [[ -f "$stamp" ]]; then
    local age=$(( $(date +%s) - $(_opencode_mtime "$stamp") ))
    (( age >= 0 && age < ttl )) && return 0
  fi
  date +%s > "$stamp"
  local -a ids
  ids=($(opencode session list --format json 2>/dev/null | python3 -c '
import json, sys
title, keep = sys.argv[1], int(sys.argv[2])
try:
    data = json.load(sys.stdin)
except Exception:
    data = []
ids = [s.get("id") for s in data if s.get("title") == title and s.get("id")]
print("\n".join(ids[keep:]))
' "$title" "$keep"))
  local id
  for id in "${ids[@]}"; do
    [[ -n "$id" ]] && opencode session delete "$id" >/dev/null 2>&1
  done
}

_opencode_pick_model() {
  local requested="${1:-}"
  if [[ -n "$requested" ]]; then
    printf '%s\n' "$requested"
    return 0
  fi

  local cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/opencode"
  local cache_file="$cache_dir/pick-model"
  local ttl="${OPENCODE_MODEL_CACHE_TTL:-3600}"
  if [[ -f "$cache_file" ]]; then
    local age=$(( $(date +%s) - $(_opencode_mtime "$cache_file") ))
    if (( age >= 0 && age < ttl )); then
      local cached
      cached=$(<"$cache_file")
      [[ -n "$cached" ]] && { printf '%s\n' "$cached"; return 0; }
    fi
  fi

  mkdir -p "$cache_dir"
  local picked
  picked=$(timeout 3 opencode models 2>/dev/null | python3 -c '
import json, os, sys
live = {line.strip() for line in sys.stdin if line.strip()}
cache = os.path.join(os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache"), "opencode", "models.json")
try:
    data = json.load(open(cache))
except Exception:
    data = {}
bad = ("-vl", "vision", "omni", "embed", "tts", "image", "audio")
preferred = ("deepseek-v4.1-flash-free", "big-pickle", "glm-5.3-flash-free", "minimax-m3.1-flash-free", "qwen3.6-plus-free")
free = []
for model, meta in ((data.get("opencode") or {}).get("models") or {}).items():
    low = model.lower()
    if any(marker in low for marker in bad):
        continue
    cost = meta.get("cost") or {}
    if cost.get("input") == 0 and cost.get("output") == 0:
        limit = meta.get("limit") or {}
        free.append((limit.get("context") or 0, limit.get("output") or 0, f"opencode/{model}"))
free.sort(reverse=True)
best_pref = next((f"opencode/{m}" for m in preferred if not live or f"opencode/{m}" in live), None)
best_live = next((mid for _, _, mid in free if mid in live), None)
best_cached = free[0][2] if free else None
print(best_pref or best_live or best_cached or "opencode/deepseek-v4.1-flash-free")
')
  [[ -n "$picked" ]] || picked="opencode/deepseek-v4.1-flash-free"
  printf '%s\n' "$picked" | tee "$cache_file"
}

cmg() {
  local state="" type="chore" scope="root" files="" diff_output="" file_count=0
  local src_branch="" dst_branch="" inc_commits="" commit_msg="" fallback_msg=""
  local cmg_model="${CMG_MODEL:-}"
  cmg_model=$(_opencode_pick_model "$cmg_model")
  [[ -n "$cmg_model" ]] || cmg_model="opencode/big-pickle"
  local -a diff_args

  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "cmg: not inside a git repository" >&2
    return 1
  fi

  # Detect git state
  if git rev-parse --verify MERGE_HEAD &>/dev/null; then
    state="merge"
    src_branch=$(git rev-parse --abbrev-ref MERGE_HEAD 2>/dev/null | sed 's|remotes/origin/||')
    dst_branch=$(git rev-parse --abbrev-ref HEAD)
    inc_commits=$(git log --oneline HEAD..MERGE_HEAD 2>/dev/null)
    files=$(git diff MERGE_HEAD --name-only 2>/dev/null)
    diff_args=(MERGE_HEAD)
    diff_output=$(git diff "${diff_args[@]}" --stat 2>/dev/null)
    type="merge"
  elif git rev-parse --verify REBASE_HEAD &>/dev/null; then
    state="rebase"
    files=$(git diff REBASE_HEAD --name-only)
    diff_args=(REBASE_HEAD)
    diff_output=$(git diff "${diff_args[@]}" --stat)
    type="rebase"
  elif git rev-parse --verify CHERRY_PICK_HEAD &>/dev/null; then
    state="cherry-pick"
    files=$(git diff CHERRY_PICK_HEAD --name-only)
    diff_args=(CHERRY_PICK_HEAD)
    diff_output=$(git diff "${diff_args[@]}" --stat)
    type="cherry-pick"
  fi

  # Fallback: normal state
  if [[ -z "$state" ]]; then
    files=$(git diff --cached --name-only 2>/dev/null)
    if [[ -n "$files" ]]; then
      state="staged"
      diff_args=(--cached)
      diff_output=$(git diff "${diff_args[@]}" --stat)
    else
      state="unstaged"
      files=$(git diff --name-only)
      diff_args=()
      diff_output=$(git diff --stat)
    fi
  fi

  if [[ -n "$files" ]]; then
    file_count=$(printf "%s\n" "$files" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')
  else
    file_count=0
  fi

  if [[ "$file_count" -eq 0 ]]; then
    echo "cmg: no staged or unstaged changes found" >&2
    return 1
  fi

  # Auto-detect type from paths (skip if set by state)
  if [[ "$type" == "chore" ]]; then
    if echo "$files" | grep -q "/test_\|/tests/\|test_factories\|test_runner"; then
      type="test"
    elif echo "$files" | grep -q "/migrations/"; then
      type="feat"; scope="migrations"
    elif echo "$files" | grep -qi "fix\|hotfix"; then
      type="fix"
    elif echo "$files" | grep -q "^docs/\|README\|\.md$"; then
      type="docs"
    elif echo "$files" | grep -q "\.py$" && ! echo "$files" | grep -q "test"; then
      if echo "$files" | grep -q "service\|selector\|view\|model\|serializer"; then
        type="feat"
      else
        type="refactor"
      fi
    fi
  fi

  # Detect scope
  if [[ "$type" != "merge" ]]; then
    scope=$(echo "$files" | grep -v '^\.' | sed 's|/.*||' | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')
    [[ -z "$scope" ]] && scope=$(echo "$files" | grep '^[a-z]' | sed 's|/.*||' | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')
    [[ -z "$scope" ]] && scope="root"

    if [[ "$type" == "docs" ]]; then
      local docs_scope
      docs_scope=$(echo "$files" | sed -n 's|^docs/\([^/]*\)/.*|\1|p' | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')
      [[ -n "$docs_scope" ]] && scope="$docs_scope"
    fi
  fi

  # Output
  echo ""
  echo "┌─ Commit Preview ─────────────────────────────"
  if [[ "$state" == "merge" ]]; then
    echo "│ Merge branch '$src_branch' → '$dst_branch'"
    [[ -n "$inc_commits" ]] && echo "│" && echo "$inc_commits" | while IFS= read -r line; do echo "│  • $line"; done
    echo "│"
  fi
  echo "│ Type: $type  Scope: $scope  State: $state  Files: $file_count"
  echo "├──────────────────────────────────────────────"
  if [[ -n "$files" ]]; then
    echo "$files" | head -30 | while IFS= read -r f; do
      [[ -n "$f" ]] && echo "│  $f"
    done
  fi
  local remaining=$((file_count - 30))
  [[ $remaining -gt 0 ]] 2>/dev/null && echo "│  ... +$remaining more files"
  echo "├─ Diff ───────────────────────────────────────"
  if [[ -n "$diff_output" ]]; then
    echo "$diff_output" | head -20 | while IFS= read -r line; do echo "│ $line"; done
  fi
  local diff_lines=$(echo "$diff_output" | wc -l | tr -d ' ')
  [[ $diff_lines -gt 20 ]] 2>/dev/null && echo "│ ... ($((diff_lines - 20)) more lines)"
  echo "└──────────────────────────────────────────────"
  echo ""

  # Build fallback commit message suggestion
  if [[ "$state" == "merge" ]]; then
    fallback_msg="merge: $src_branch into $dst_branch"
  elif [[ "$type" == "merge" ]]; then
    fallback_msg="merge: $src_branch into $dst_branch"
  elif [[ -n "$scope" && "$scope" != "root" ]]; then
    fallback_msg="$type($scope): update changes"
  else
    fallback_msg="$type: update changes"
  fi

  commit_msg="$fallback_msg"

  # Generate a real message from the diff when OpenCode is available.
  if [[ "$type" != "merge" ]] && command -v opencode >/dev/null 2>&1; then
    local cmg_context cmg_prompt ai_msg cmg_diff_lines
    cmg_context=$(mktemp "${TMPDIR:-/tmp}/cmg.XXXXXX") || return 1
    cmg_diff_lines="${CMG_DIFF_LINES:-400}"
    [[ "$cmg_diff_lines" =~ '^[0-9]+$' ]] || cmg_diff_lines=400

    {
      printf '# Commit context\n\n'
      printf 'State: %s\nType: %s\nScope: %s\nFiles: %s\n\n' "$state" "$type" "$scope" "$file_count"
      printf 'Preferred prefix: %s\n\n' "${fallback_msg%% update changes}"
      printf '## Git status\n'
      git status --short 2>/dev/null
      printf '\n## Changed files\n%s\n\n' "$files"
      printf '## Diff stat\n%s\n\n' "$diff_output"
      printf '## Diff (first %s lines)\n' "$cmg_diff_lines"
      git diff "${diff_args[@]}" --no-ext-diff --unified=3 2>/dev/null | sed -n "1,${cmg_diff_lines}p"
    } > "$cmg_context"

    cmg_prompt="Generate one Conventional Commit message for the attached git diff. Return exactly one line, no markdown, no quotes, and no git command. Use English. Prefer the provided prefix unless the diff clearly needs a better type or scope. Summarize the actual change, not the file list. Keep it under 100 characters. Valid types: feat, fix, docs, refactor, test, chore, build, ci, perf, style, revert."

    echo "Generating commit message with $cmg_model..."
    if command -v node >/dev/null 2>&1; then
      ai_msg=$(timeout "${CMG_TIMEOUT:-120}" opencode run -m "$cmg_model" --archived --format json --title cmg "$cmg_prompt" --file "$cmg_context" 2>/dev/null | node -e 'let input=""; process.stdin.on("data", d => input += d); process.stdin.on("end", () => { let text = ""; for (const line of input.split(/\r?\n/)) { if (!line.trim()) continue; try { const event = JSON.parse(line); if (event.type === "text" && event.part && typeof event.part.text === "string") text += event.part.text; } catch (_) {} } process.stdout.write(text.trim()); });')
    else
      ai_msg=$(timeout "${CMG_TIMEOUT:-120}" opencode run -m "$cmg_model" --archived --title cmg "$cmg_prompt" --file "$cmg_context" 2>/dev/null | sed -E $'s/\x1B\\[[0-9;]*[A-Za-z]//g' | sed '/^$/d;/^> /d' | tail -1)
    fi
    rm -f "$cmg_context"

    ai_msg=$(printf "%s\n" "$ai_msg" | sed -E 's/^```[a-zA-Z]*$//' | sed -E 's/^[[:space:]"`]+//; s/[[:space:]"`]+$//' | grep -E '^(feat|fix|docs|refactor|test|chore|build|ci|perf|style|revert)(\([a-zA-Z0-9._-]+\))?: .+' | tail -1)
    if [[ "$ai_msg" =~ '^(feat|fix|docs|refactor|test|chore|build|ci|perf|style|revert)(\([a-zA-Z0-9._-]+\))?: .+' ]]; then
      commit_msg="$ai_msg"
    else
      echo "cmg: AI did not return a valid Conventional Commit; using fallback." >&2
    fi
  fi

  # Cleanup once a day; --archived keeps these out of the TUI meanwhile.
  _opencode_session_cleanup cmg 0

  local commit_msg_for_shell=${commit_msg//\\/\\\\}
  commit_msg_for_shell=${commit_msg_for_shell//\"/\\\"}

  echo "Suggested:"
  printf '  git commit -m "%s"\n' "$commit_msg_for_shell"
  echo ""
}

# ---- Global opencode task runner ----
doit() {
  local doit_model="${DOIT_MODEL:-}"
  doit_model=$(_opencode_pick_model "$doit_model")
  [[ -n "$doit_model" ]] || doit_model="opencode/big-pickle"
  local doit_dir="$PWD"
  local doit_skip_permissions="${DOIT_SKIP_PERMISSIONS:-1}"
  local doit_interactive=0
  local user_request="" doit_prompt="" doit_context="" doit_status=0
  local -a doit_args

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ask|--safe|--no-auto-allow)
        doit_skip_permissions=0
        shift
        ;;
      --allow|--auto-allow|--yes)
        doit_skip_permissions=1
        shift
        ;;
      -i|--interactive)
        doit_interactive=1
        shift
        ;;
      -C|--dir)
        shift
        if [[ $# -eq 0 || -z "$1" ]]; then
          echo "doit: --dir requires a directory" >&2
          return 2
        fi
        doit_dir="$1"
        shift
        ;;
      --dir=*)
        doit_dir="${1#--dir=}"
        shift
        ;;
      -m|--model)
        shift
        if [[ $# -eq 0 || -z "$1" ]]; then
          echo "doit: --model requires provider/model" >&2
          return 2
        fi
        doit_model="$1"
        shift
        ;;
      --model=*)
        doit_model="${1#--model=}"
        shift
        ;;
      -h|--help)
        cat <<'EOF'
Usage: doit [options] "task"

Run an arbitrary task through opencode using a free Zen text model by default.

Options:
  --ask, --safe          Use normal opencode permission prompts.
  --allow, --auto-allow  Auto-approve permissions. Default.
  -C, --dir DIR          Run opencode from DIR instead of the current directory.
  -m, --model MODEL      Override model. Default: cached free Zen text model.
  -i, --interactive      Open the TUI with the task instead of a scripted run.
  -h, --help             Show this help.

Environment:
  DOIT_MODEL             Default model override.
  DOIT_SKIP_PERMISSIONS  Set to 0 to make --ask the default.

Examples:
  doit "move markdown file to repo ~/projects/repo/docs/analysis"
  doit --ask "inspect this repo and suggest next steps"
  doit -C ~/projects/repo "organize docs/analysis markdown files"
EOF
        return 0
        ;;
      --)
        shift
        break
        ;;
      -*)
        echo "doit: unknown option: $1" >&2
        echo "doit: run 'doit --help' for usage" >&2
        return 2
        ;;
      *)
        break
        ;;
    esac
  done

  if [[ $# -eq 0 ]]; then
    echo "doit: missing task" >&2
    echo "doit: run 'doit --help' for usage" >&2
    return 2
  fi

  if ! command -v opencode >/dev/null 2>&1; then
    echo "doit: opencode not found in PATH" >&2
    return 1
  fi

  if [[ ! -d "$doit_dir" ]]; then
    echo "doit: directory does not exist: $doit_dir" >&2
    return 1
  fi

  user_request="$*"
  doit_context=$(mktemp "${TMPDIR:-/tmp}/doit.XXXXXX") || return 1
  {
    printf "You are the automation agent behind the user's doit shell command.\n\n"
    printf 'User request:\n%s\n\n' "$user_request"
    printf 'Starting directory:\n%s\n\n' "$doit_dir"
    printf 'Operate end-to-end from this directory, using absolute paths from the request exactly when provided. You may inspect files, edit files, move files, and run commands as needed. Be careful with destructive operations: ask for clarification instead of deleting, overwriting important data, resetting git state, force-pushing, or touching secrets unless the user explicitly requested it. Preserve unrelated git changes. Do not commit, amend, or push unless explicitly asked. When finished, summarize what changed and any verification performed.\n'
  } > "$doit_context"
  doit_prompt="Execute the task described in the attached doit context."

  doit_args=(run -m "$doit_model" --title doit)
  if [[ "$doit_skip_permissions" != "0" ]]; then
    doit_args+=(--auto)
  fi

  echo "doit: opencode model=$doit_model dir=$doit_dir"
  if [[ "$doit_skip_permissions" != "0" ]]; then
    echo "doit: auto-allow enabled; use --ask to review permissions"
  fi

  if [[ "$doit_interactive" == "1" ]]; then
    ( cd "$doit_dir" && opencode --prompt "$doit_prompt"$'\n\n'"$(<"$doit_context")" )
  else
    ( cd "$doit_dir" && opencode "${doit_args[@]}" --archived "$doit_prompt" --file "$doit_context" )
  fi
  doit_status=$?
  rm -f "$doit_context"
  _opencode_session_cleanup doit 1
  return "$doit_status"
}

# ---- Branch name generator ----
unalias bng 2>/dev/null
bng() {
  local bng_model="${BNG_MODEL:-}"
  bng_model=$(_opencode_pick_model "$bng_model")
  [[ -n "$bng_model" ]] || bng_model="opencode/big-pickle"
  local -a diff_args=()

  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "bng: not inside a git repository" >&2
    return 1
  fi

  local files=$(git diff --cached --name-only 2>/dev/null)
  if [[ -n "$files" ]]; then
    diff_args=(--cached)
  else
    files=$(git diff --name-only)
    diff_args=()
  fi

  if [[ -z "$files" ]]; then
    echo "bng: no staged or unstaged changes found" >&2
    return 1
  fi

  local bng_context=$(mktemp "${TMPDIR:-/tmp}/bng.XXXXXX") || return 1
  {
    printf '# Diff\n```diff\n'
    git diff "${diff_args[@]}" --no-ext-diff --unified=3 2>/dev/null | head -2000
    printf '\n```\n'
  } > "$bng_context"

  local bng_prompt="Generate a short git branch name (kebab-case, max 40 chars) for the attached diff. Return exactly one line: the branch name only, no markdown, no quotes, no explanation. Prefix with feat/ fix/ refactor/ chore/ test/ docs/ based on the change type. Examples: feat/add-login-page, fix/null-pointer-crash, refactor/simplify-auth."

  echo "Generating branch name with $bng_model..."
  local ai_name
  if command -v node >/dev/null 2>&1; then
    ai_name=$(timeout "${BNG_TIMEOUT:-120}" opencode run -m "$bng_model" --archived --format json --title bng "$bng_prompt" --file "$bng_context" 2>/dev/null | node -e 'let input=""; process.stdin.on("data", d => input += d); process.stdin.on("end", () => { let text = ""; for (const line of input.split(/\r?\n/)) { if (!line.trim()) continue; try { const event = JSON.parse(line); if (event.type === "text" && event.part && typeof event.part.text === "string") text += event.part.text; } catch (_) {} } process.stdout.write(text.trim()); });')
  else
    ai_name=$(timeout "${BNG_TIMEOUT:-120}" opencode run -m "$bng_model" --archived --title bng "$bng_prompt" --file "$bng_context" 2>/dev/null | sed -E $'s/\x1B\\[[0-9;]*[A-Za-z]//g' | sed '/^$/d;/^> /d' | tail -1)
  fi
  rm -f "$bng_context"

  ai_name=$(printf "%s\n" "$ai_name" | sed -E 's/^```[a-zA-Z]*$//' | sed -E 's/^[[:space:]"`]+//; s/[[:space:]"`]+$//' | sed '/^$/d' | tail -1)

  local branch_name
  if [[ -n "$ai_name" && ${#ai_name} -le 60 ]]; then
    branch_name="$ai_name"
  else
    branch_name="branch-$(date +%Y%m%d-%H%M%S)"
    echo "bng: AI did not return a valid branch name; using fallback." >&2
  fi

  echo "→ $branch_name"
  git checkout -b "$branch_name"
  _opencode_session_cleanup bng 0
}

# Natural-language task text often contains zsh glob syntax like parentheses.
alias cmg='noglob cmg'
alias doit='noglob doit'
alias bng='noglob bng'

