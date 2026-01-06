#!/usr/bin/env bash
#
# ralph.sh - Ralph Wiggum loop implementation
# Based on Matt Pocock's approach with Docker sandbox support
#
set -e

ITERATIONS="${1:-50}"
USE_DOCKER="${USE_DOCKER:-true}"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PROMPT='@prd.json @progress.txt
1. Find the highest-priority incomplete feature (tested: false) and work ONLY on that feature.
   Choose based on YOUR judgment of priority - not necessarily first in list.
2. Run tests/typechecks before committing (check package.json for commands).
3. Update prd.json: set tested: true for completed features.
4. Append your progress to progress.txt - leave notes for the next iteration.
5. Make a git commit for that feature.
ONLY WORK ON A SINGLE FEATURE.
If PRD is complete (all tested: true), output <promise>COMPLETE</promise>.'

# Check required files
if [[ ! -f "prd.json" ]]; then
    echo -e "${YELLOW}[ralph]${NC} No prd.json found. Create one with your features."
    exit 1
fi

if [[ ! -f "progress.txt" ]]; then
    echo "# Ralph Progress Log" > progress.txt
    echo "Started: $(date)" >> progress.txt
    echo "" >> progress.txt
fi

echo -e "${GREEN}[ralph]${NC} Starting Ralph Wiggum loop ($ITERATIONS iterations max)"
echo -e "${GREEN}[ralph]${NC} Docker sandbox: $USE_DOCKER"

for ((i=1; i<=ITERATIONS; i++)); do
    echo -e "${GREEN}[ralph]${NC} === Iteration $i/$ITERATIONS ==="

    if [[ "$USE_DOCKER" == "true" ]]; then
        result=$(docker sandbox run claude -p "$PROMPT")
    else
        result=$(claude --dangerously-skip-permissions -p "$PROMPT")
    fi

    echo "$result"

    if [[ "$result" == *"<promise>COMPLETE</promise>"* ]]; then
        echo -e "${GREEN}[ralph]${NC} PRD complete after $i iterations!"
        echo "Completed: $(date)" >> progress.txt
        exit 0
    fi
done

echo -e "${YELLOW}[ralph]${NC} Finished $ITERATIONS iterations (PRD may not be complete)"
echo "Stopped after $ITERATIONS iterations: $(date)" >> progress.txt
