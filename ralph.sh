#!/usr/bin/env bash
#
# ralph.sh - Ralph Wiggum loop with git worktree isolation
# Based on Matt Pocock's approach
#
set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo -e "${GREEN}[ralph]${NC} $1"; }
warn() { echo -e "${YELLOW}[ralph]${NC} $1"; }
error() { echo -e "${RED}[ralph]${NC} $1"; }

# Defaults
ITERATIONS=50
INIT_DESC=""
MAIN_REPO=""
WORKTREE_PATH=""
WORKTREE_BRANCH=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --init)
            INIT_DESC="$2"
            shift 2
            ;;
        -n|--iterations)
            ITERATIONS="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: ralph [options]"
            echo ""
            echo "Options:"
            echo "  --init \"description\"  Bootstrap mode: generate PRD from description"
            echo "  -n, --iterations N    Max iterations (default: 50)"
            echo "  -h, --help            Show this help"
            echo ""
            echo "Files:"
            echo "  prd.json              Task list (required unless using --init)"
            echo "  RALPH_TOOLS.md        Project-specific instructions (optional)"
            exit 0
            ;;
        *)
            # Assume it's iteration count for backwards compat
            if [[ "$1" =~ ^[0-9]+$ ]]; then
                ITERATIONS="$1"
            fi
            shift
            ;;
    esac
done

# --- Utility Functions ---

detect_pkg_manager() {
    if [[ -f "bun.lockb" ]]; then echo "bun"
    elif [[ -f "pnpm-lock.yaml" ]]; then echo "pnpm"
    elif [[ -f "yarn.lock" ]]; then echo "yarn"
    elif [[ -f "package-lock.json" ]]; then echo "npm"
    else echo "unknown"
    fi
}

is_worktree() {
    [[ -f "$(git rev-parse --git-dir)/commondir" ]]
}

get_main_branch() {
    git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || echo "main"
}

list_ralph_worktrees() {
    git worktree list | grep -E "ralph-[0-9]+" | awk '{print $1, $3}' || true
}

create_worktree() {
    local name="ralph-$(date +%Y%m%d-%H%M%S)"
    local repo_name=$(basename "$PWD")
    local path="../${repo_name}-${name}"

    log "Creating worktree: $path"
    git worktree add "$path" -b "$name" 2>&1

    WORKTREE_PATH="$path"
    WORKTREE_BRANCH="$name"
}

cleanup_worktree() {
    if [[ -n "$WORKTREE_PATH" && -d "$WORKTREE_PATH" ]]; then
        log "Removing worktree: $WORKTREE_PATH"
        git worktree remove "$WORKTREE_PATH" --force 2>/dev/null || true
        git branch -D "$WORKTREE_BRANCH" 2>/dev/null || true
    fi
}

# Handle Ctrl+C
trap_handler() {
    echo ""
    warn "Interrupted!"
    if [[ -n "$WORKTREE_PATH" ]]; then
        warn "Worktree preserved at: $WORKTREE_PATH"
        warn "To clean up: git worktree remove $WORKTREE_PATH"
    fi
    exit 130
}
trap trap_handler INT TERM

# --- Pre-flight Checks ---

# Must be in a git repo
if ! git rev-parse --git-dir &>/dev/null; then
    error "Not a git repository"
    exit 1
fi

# Notify if in worktree
if is_worktree; then
    warn "Running from within a worktree"
fi

# Notify if dirty
if [[ -n $(git status --porcelain) ]]; then
    warn "Working directory has uncommitted changes"
fi

# Check for prd.json (unless --init mode)
if [[ -z "$INIT_DESC" && ! -f "prd.json" ]]; then
    error "No prd.json found. Create one or use --init \"description\""
    exit 1
fi

# --- Worktree Setup ---

MAIN_REPO="$PWD"
existing_worktrees=$(list_ralph_worktrees)

if [[ -n "$existing_worktrees" ]]; then
    log "Existing ralph worktrees:"
    echo "$existing_worktrees"
    echo ""
    read -p "Enter path to use, or press Enter for [new]: " choice

    if [[ -n "$choice" && -d "$choice" ]]; then
        WORKTREE_PATH="$choice"
        WORKTREE_BRANCH=$(basename "$choice")
        log "Using existing worktree: $WORKTREE_PATH"
    else
        create_worktree
    fi
else
    create_worktree
fi

# Move to worktree
cd "$WORKTREE_PATH"
log "Working in: $PWD"

# --- Setup Files in Worktree ---

# Copy or create prd.json
if [[ -n "$INIT_DESC" ]]; then
    log "Bootstrap mode: will generate PRD from description"
    # Create minimal prd.json that tells Claude to populate it
    cat > prd.json <<EOF
[
  {
    "feature": "Generate PRD",
    "description": "Analyze the project description and create detailed feature entries in this prd.json file",
    "tested": false
  }
]
EOF
elif [[ -f "$MAIN_REPO/prd.json" ]]; then
    cp "$MAIN_REPO/prd.json" ./prd.json
fi

# Create progress.txt
cat > progress.txt <<EOF
# Ralph Progress Log
Started: $(date)
Main repo: $MAIN_REPO
Worktree: $WORKTREE_PATH

EOF

# --- Detect Environment ---

PKG_MANAGER=$(detect_pkg_manager)
log "Package manager: $PKG_MANAGER"

# Load RALPH_TOOLS.md if exists
TOOLS_CONTENT=""
if [[ -f "$MAIN_REPO/RALPH_TOOLS.md" ]]; then
    TOOLS_CONTENT=$(cat "$MAIN_REPO/RALPH_TOOLS.md")
    log "Loaded RALPH_TOOLS.md"
fi

# --- Build Prompt ---

build_prompt() {
    local prompt="@prd.json @progress.txt

## Package Manager
Use \`$PKG_MANAGER\` for all package operations (install, test, build, etc).
"

    if [[ -n "$INIT_DESC" ]]; then
        prompt+="
## Project Description
$INIT_DESC

First, analyze this description and populate prd.json with detailed feature entries.
Then proceed to implement them one by one.
"
    fi

    if [[ -n "$TOOLS_CONTENT" ]]; then
        prompt+="
## Project Tools
$TOOLS_CONTENT
"
    else
        prompt+="
## Project Tools
No RALPH_TOOLS.md found. Discover test/build commands from package.json or project files.
"
    fi

    prompt+="
## Instructions
1. Find the highest-priority incomplete feature (tested: false) - work ONLY on that
2. Run tests/typechecks before committing (discover commands from project files)
3. Update prd.json: set tested: true for completed features
4. Append your progress to progress.txt - leave notes for next iteration
5. Make a git commit for that feature

ONLY WORK ON A SINGLE FEATURE.
If PRD is complete (all tested: true), output <promise>COMPLETE</promise>"

    echo "$prompt"
}

# --- Main Loop ---

log "Starting Ralph Wiggum loop ($ITERATIONS iterations max)"

for ((i=1; i<=ITERATIONS; i++)); do
    log "=== Iteration $i/$ITERATIONS ==="

    PROMPT=$(build_prompt)
    result=$(claude --dangerously-skip-permissions -p "$PROMPT" 2>&1) || true

    echo "$result"

    if [[ "$result" == *"<promise>COMPLETE</promise>"* ]]; then
        log "PRD complete after $i iterations!"
        echo "Completed: $(date)" >> progress.txt
        break
    fi
done

# --- Completion Flow ---

echo ""
log "Ralph loop finished"
echo ""

MAIN_BRANCH=$(get_main_branch)

log "Changes in worktree vs $MAIN_BRANCH:"
git log "$MAIN_BRANCH..HEAD" --oneline 2>/dev/null || echo "(no commits)"
echo ""
git diff --stat "$MAIN_BRANCH..HEAD" 2>/dev/null || true
echo ""

read -p "Merge to $MAIN_BRANCH? [y/n/i(nspect)] " merge_choice

case $merge_choice in
    y|Y)
        cd "$MAIN_REPO"
        git merge "$WORKTREE_BRANCH" --no-edit
        cleanup_worktree
        log "Merged and cleaned up!"
        ;;
    i|I)
        log "Worktree at: $WORKTREE_PATH"
        log "Inspect changes, then run:"
        echo "  cd $MAIN_REPO"
        echo "  git merge $WORKTREE_BRANCH"
        echo "  git worktree remove $WORKTREE_PATH"
        ;;
    *)
        log "Worktree preserved at: $WORKTREE_PATH"
        log "To clean up later:"
        echo "  git worktree remove $WORKTREE_PATH"
        ;;
esac
