#!/bin/bash
#
# AISdb-Lite Documentation Audit Runner
# Executes audit prompts sequentially using Claude Code agents
# Supports resuming from failures and automatic retries
#
# Usage: ./run_audit.sh [OPTIONS] [START] [END]
#
# Options:
#   --no-git        Skip git commit/push at the end
#   --resume        Resume from last failed run (ignore START/END)
#   --reset         Clear checkpoint and start fresh
#   --status        Show current checkpoint status and exit
#   --retry N       Number of retries per prompt (default: 2)
#   --help          Show this help message
#
# Arguments:
#   START           Start from this prompt number (default: 0)
#   END             End at this prompt number (default: 4)
#
# Execution Order: 0 → 1 → 2 → 3 → 4
#
# File Access Rules:
#   - Prompt 0: Can modify 0-REPORT.md, 0-CHANGELOG.md
#   - Prompt 1: Can modify 1-REPORT.md, 1-CHANGELOG.md
#   - Prompt 2: Can modify 2-REPORT.md, 2-CHANGELOG.md
#   - Prompt 3: Can modify 0,1,2,3-REPORT.md and 0,1,2,3-CHANGELOG.md
#   - Prompt 4: Reads 0,1,2-REPORT.md; Can modify 4-REPORT.md, 4-CHANGELOG.md
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
LOG_DIR="${SCRIPT_DIR}/logs"
CHECKPOINT_FILE="${SCRIPT_DIR}/.audit_checkpoint"

# Parse arguments
DO_GIT=true
RESUME_MODE=false
RESET_MODE=false
STATUS_MODE=false
MAX_RETRIES=2
START=""
END=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --no-git)
            DO_GIT=false
            shift
            ;;
        --resume)
            RESUME_MODE=true
            shift
            ;;
        --reset)
            RESET_MODE=true
            shift
            ;;
        --status)
            STATUS_MODE=true
            shift
            ;;
        --retry)
            MAX_RETRIES=$2
            shift 2
            ;;
        --help)
            head -30 "$0" | tail -28
            exit 0
            ;;
        *)
            if [[ -z "$START" ]]; then
                START=$1
            elif [[ -z "$END" ]]; then
                END=$1
            else
                echo "Unknown option: $1"
                echo "Use --help for usage information"
                exit 1
            fi
            shift
            ;;
    esac
done

# Default values
START=${START:-0}
END=${END:-4}

# Create logs directory
mkdir -p "${LOG_DIR}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Prompt descriptions
declare -A DESCRIPTIONS
DESCRIPTIONS=(
    [0]="Architecture Documentation"
    [1]="Bug Analysis"
    [2]="Bad Business Decisions"
    [3]="Cross-Report Contradiction Analysis"
    [4]="Engineering Blueprint"
)

# Files each prompt can modify
declare -A CAN_MODIFY
CAN_MODIFY=(
    [0]="0-REPORT.md, 0-CHANGELOG.md"
    [1]="1-REPORT.md, 1-CHANGELOG.md"
    [2]="2-REPORT.md, 2-CHANGELOG.md"
    [3]="0-REPORT.md, 0-CHANGELOG.md, 1-REPORT.md, 1-CHANGELOG.md, 2-REPORT.md, 2-CHANGELOG.md, 3-REPORT.md, 3-CHANGELOG.md"
    [4]="4-REPORT.md, 4-CHANGELOG.md"
)

# Reports each prompt should read
declare -A REPORTS_TO_READ
REPORTS_TO_READ=(
    [0]=""
    [1]=""
    [2]=""
    [3]="0-REPORT.md, 1-REPORT.md, 2-REPORT.md"
    [4]="0-REPORT.md, 1-REPORT.md, 2-REPORT.md"
)

# Allowed tools for audit agents
ALLOWED_TOOLS="Read,Grep,Glob,Bash,Task,TodoWrite,Edit,Write,WebSearch,WebFetch"

# Max turns per prompt
declare -A MAX_TURNS
MAX_TURNS=(
    [0]=150
    [1]=150
    [2]=150
    [3]=100
    [4]=150
)

# ═══════════════════════════════════════════════════════════════════════════════
# CHECKPOINT FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════════

# Initialize or load checkpoint
load_checkpoint() {
    if [[ -f "$CHECKPOINT_FILE" ]]; then
        source "$CHECKPOINT_FILE"
    else
        CHECKPOINT_RUN_ID=""
        CHECKPOINT_START=0
        CHECKPOINT_END=4
        CHECKPOINT_COMPLETED=""
        CHECKPOINT_FAILED=""
        CHECKPOINT_IN_PROGRESS=""
    fi
}

# Save checkpoint state
save_checkpoint() {
    cat > "$CHECKPOINT_FILE" << EOF
# Audit checkpoint - DO NOT EDIT MANUALLY
# Generated: $(date -Iseconds)
CHECKPOINT_RUN_ID="${CHECKPOINT_RUN_ID}"
CHECKPOINT_START=${CHECKPOINT_START}
CHECKPOINT_END=${CHECKPOINT_END}
CHECKPOINT_COMPLETED="${CHECKPOINT_COMPLETED}"
CHECKPOINT_FAILED="${CHECKPOINT_FAILED}"
CHECKPOINT_IN_PROGRESS="${CHECKPOINT_IN_PROGRESS}"
EOF
}

# Clear checkpoint
clear_checkpoint() {
    rm -f "$CHECKPOINT_FILE"
    CHECKPOINT_RUN_ID=""
    CHECKPOINT_START=0
    CHECKPOINT_END=4
    CHECKPOINT_COMPLETED=""
    CHECKPOINT_FAILED=""
    CHECKPOINT_IN_PROGRESS=""
}

# Mark prompt as completed
mark_completed() {
    local num=$1
    CHECKPOINT_COMPLETED="${CHECKPOINT_COMPLETED} ${num}"
    CHECKPOINT_IN_PROGRESS=""
    # Remove from failed if present
    CHECKPOINT_FAILED=$(echo "$CHECKPOINT_FAILED" | sed "s/ ${num}//g" | sed "s/^${num}//g")
    save_checkpoint
}

# Mark prompt as failed
mark_failed() {
    local num=$1
    if [[ ! "$CHECKPOINT_FAILED" =~ (^|[[:space:]])${num}($|[[:space:]]) ]]; then
        CHECKPOINT_FAILED="${CHECKPOINT_FAILED} ${num}"
    fi
    CHECKPOINT_IN_PROGRESS=""
    save_checkpoint
}

# Mark prompt as in progress
mark_in_progress() {
    local num=$1
    CHECKPOINT_IN_PROGRESS="$num"
    save_checkpoint
}

# Check if prompt is completed
is_completed() {
    local num=$1
    [[ "$CHECKPOINT_COMPLETED" =~ (^|[[:space:]])${num}($|[[:space:]]) ]]
}

# Get prompts that need to run
get_pending_prompts() {
    local pending=""
    for num in $(seq $CHECKPOINT_START $CHECKPOINT_END); do
        if ! is_completed "$num"; then
            pending="$pending $num"
        fi
    done
    echo "$pending" | xargs
}

# Show checkpoint status
show_status() {
    load_checkpoint

    echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║              Audit Checkpoint Status                       ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    if [[ -z "$CHECKPOINT_RUN_ID" ]]; then
        echo -e "${YELLOW}No active checkpoint found.${NC}"
        echo "Run ./run_audit.sh to start a new audit."
        return
    fi

    echo -e "Run ID:       ${CYAN}${CHECKPOINT_RUN_ID}${NC}"
    echo -e "Range:        ${CYAN}${CHECKPOINT_START} - ${CHECKPOINT_END}${NC}"
    echo ""

    echo "Prompt Status:"
    for num in $(seq $CHECKPOINT_START $CHECKPOINT_END); do
        local status_icon status_color status_text
        if is_completed "$num"; then
            status_icon="✓"
            status_color="${GREEN}"
            status_text="Completed"
        elif [[ "$CHECKPOINT_IN_PROGRESS" == "$num" ]]; then
            status_icon="⟳"
            status_color="${YELLOW}"
            status_text="In Progress (interrupted)"
        elif [[ "$CHECKPOINT_FAILED" =~ (^|[[:space:]])${num}($|[[:space:]]) ]]; then
            status_icon="✗"
            status_color="${RED}"
            status_text="Failed"
        else
            status_icon="○"
            status_color="${NC}"
            status_text="Pending"
        fi
        echo -e "  ${status_color}${status_icon} Prompt ${num}${NC}: ${DESCRIPTIONS[$num]} - ${status_color}${status_text}${NC}"
    done

    echo ""
    local pending=$(get_pending_prompts)
    if [[ -n "$pending" ]]; then
        echo -e "Pending prompts: ${YELLOW}${pending}${NC}"
        echo ""
        echo -e "To resume: ${CYAN}./run_audit.sh --resume${NC}"
    else
        echo -e "${GREEN}All prompts completed!${NC}"
        echo -e "To start fresh: ${CYAN}./run_audit.sh --reset${NC}"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# VALIDATION FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════════

# Verify prompt output was generated/modified
verify_prompt_output() {
    local num=$1
    local run_start_time=$2
    local expected_files=""

    # Determine which files should be modified
    case $num in
        0) expected_files="0-REPORT.md" ;;
        1) expected_files="1-REPORT.md" ;;
        2) expected_files="2-REPORT.md" ;;
        3) expected_files="3-REPORT.md" ;;
        4) expected_files="4-REPORT.md" ;;
    esac

    # Check if the report file was modified after run started
    for file in $expected_files; do
        local filepath="${SCRIPT_DIR}/${file}"
        if [[ -f "$filepath" ]]; then
            local file_mtime=$(stat -c %Y "$filepath" 2>/dev/null || stat -f %m "$filepath" 2>/dev/null)
            if [[ $file_mtime -ge $run_start_time ]]; then
                return 0  # File was modified
            fi
        fi
    done

    return 1  # No expected file was modified
}

# ═══════════════════════════════════════════════════════════════════════════════
# PROGRESS INDICATOR
# ═══════════════════════════════════════════════════════════════════════════════

SPINNER_PID=""

# Start a background progress indicator
start_progress() {
    local log_file=$1
    local prompt_num=$2
    (
        local elapsed=0
        local last_size=0
        # Large, visible spinner frames
        local frames=('[    ]' '[=   ]' '[==  ]' '[=== ]' '[====]' '[ ===]' '[  ==]' '[   =]')
        while true; do
            # Get current log file size
            local current_size=$(stat -c %s "$log_file" 2>/dev/null || echo "0")
            local size_kb=$((current_size / 1024))

            # Format elapsed time
            local mins=$((elapsed / 60))
            local secs=$((elapsed % 60))
            local time_str=$(printf "%02d:%02d" $mins $secs)

            # Spinner animation
            local idx=$((elapsed % ${#frames[@]}))
            local spinner="${frames[$idx]}"

            # Activity indicator
            local activity=""
            if [[ $current_size -gt $last_size ]]; then
                activity=" ← writing"
            fi
            last_size=$current_size

            # Print status line (overwrite previous) - bright colors
            printf "\r\033[1;36m%s\033[0m \033[1;33m[Prompt %d]\033[0m Running... \033[1;32m%s\033[0m | Log: \033[1;37m%dKB\033[0m%s    " \
                "$spinner" "$prompt_num" "$time_str" "$size_kb" "$activity"

            sleep 1
            ((elapsed++))
        done
    ) &
    SPINNER_PID=$!
}

# Stop the progress indicator
stop_progress() {
    if [[ -n "$SPINNER_PID" ]] && kill -0 "$SPINNER_PID" 2>/dev/null; then
        kill "$SPINNER_PID" 2>/dev/null
        wait "$SPINNER_PID" 2>/dev/null
        SPINNER_PID=""
        # Clear the spinner line
        printf "\r%80s\r" " "
    fi
}

# Cleanup on exit
trap 'stop_progress' EXIT

# ═══════════════════════════════════════════════════════════════════════════════
# PROMPT EXECUTION
# ═══════════════════════════════════════════════════════════════════════════════

# Function to run a single audit prompt
run_prompt() {
    local num=$1
    local attempt=$2
    local prompt_file="${SCRIPT_DIR}/${num}-PROMPT.md"
    local log_file="${LOG_DIR}/prompt-${num}-${CHECKPOINT_RUN_ID}.log"
    local description="${DESCRIPTIONS[$num]}"
    local can_modify="${CAN_MODIFY[$num]}"
    local reports_to_read="${REPORTS_TO_READ[$num]}"
    local max_turns="${MAX_TURNS[$num]}"

    echo -e "${YELLOW}[Prompt ${num}]${NC} Starting: ${description} (attempt ${attempt}/${MAX_RETRIES})"
    echo -e "${YELLOW}[Prompt ${num}]${NC} Log file: ${log_file}"

    # Verify prompt file exists
    if [[ ! -f "${prompt_file}" ]]; then
        echo -e "${RED}[Prompt ${num}] ERROR: Prompt file not found: ${prompt_file}${NC}" | tee -a "${log_file}"
        return 1
    fi

    # Record start time for validation
    local run_start_time=$(date +%s)

    # Mark as in progress
    mark_in_progress "$num"

    # Build the instruction for Claude
    local instruction="Execute the audit analysis described in the prompt file.

## Task: ${description} (Prompt ${num})

### Instructions:
1. Read and follow the instructions in ${prompt_file}
2. Analyze the AISdb-lite codebase at ${REPO_ROOT}"

    # Add reports to read if any
    if [[ -n "$reports_to_read" ]]; then
        instruction="${instruction}
3. Read these existing reports for context:"
        IFS=',' read -ra reports <<< "$reports_to_read"
        for report in "${reports[@]}"; do
            report=$(echo "$report" | xargs)
            instruction="${instruction}
   - ${SCRIPT_DIR}/${report}"
        done
    fi

    instruction="${instruction}

### File Access Rules (STRICT):
You may ONLY create or modify these files in ${SCRIPT_DIR}:"
    IFS=',' read -ra files <<< "$can_modify"
    for f in "${files[@]}"; do
        f=$(echo "$f" | xargs)
        instruction="${instruction}
   - ${f}"
    done

    instruction="${instruction}

DO NOT modify any other files. DO NOT modify source code in the repository.

### Output Requirements:
- Follow the prompt's report structure exactly
- Include all required sections and traceability
- Update the changelog with this run's changes
- Use multi-agent exploration (Task tool) for thorough analysis

Begin the analysis now. Take your time to be thorough."

    # Read the prompt file content
    local prompt_content
    prompt_content=$(cat "${prompt_file}")

    # Full prompt
    local full_prompt="${instruction}

---

# PROMPT FILE CONTENT (${num}-PROMPT.md):

${prompt_content}"

    # Run Claude with the prompt
    local exit_code=0

    # Start progress indicator
    start_progress "${log_file}" "${num}"

    (
        cd "${REPO_ROOT}" || exit 1

        if command -v stdbuf &> /dev/null; then
            stdbuf -oL claude --print \
                --dangerously-skip-permissions \
                --allowedTools "${ALLOWED_TOOLS}" \
                --max-turns "${max_turns}" \
                "${full_prompt}" \
                2>&1
        else
            claude --print \
                --dangerously-skip-permissions \
                --allowedTools "${ALLOWED_TOOLS}" \
                --max-turns "${max_turns}" \
                "${full_prompt}" \
                2>&1
        fi
    ) >> "${log_file}" 2>&1

    exit_code=$?

    # Stop progress indicator
    stop_progress

    # Validate output was generated
    if [[ $exit_code -eq 0 ]]; then
        # Give filesystem a moment to sync
        sleep 2

        if verify_prompt_output "$num" "$run_start_time"; then
            echo -e "${GREEN}[Prompt ${num}] Completed and verified successfully${NC}"
            return 0
        else
            echo -e "${RED}[Prompt ${num}] Claude exited OK but no output detected${NC}"
            return 1
        fi
    else
        echo -e "${RED}[Prompt ${num}] Failed with exit code: ${exit_code}${NC}"
        return 1
    fi
}

# Run prompt with retries
run_prompt_with_retry() {
    local num=$1
    local attempt=1

    while [[ $attempt -le $MAX_RETRIES ]]; do
        if run_prompt "$num" "$attempt"; then
            mark_completed "$num"
            return 0
        fi

        echo -e "${YELLOW}[Prompt ${num}] Attempt ${attempt}/${MAX_RETRIES} failed${NC}"

        if [[ $attempt -lt $MAX_RETRIES ]]; then
            echo -e "${YELLOW}[Prompt ${num}] Waiting 10 seconds before retry...${NC}"
            sleep 10
        fi

        ((attempt++))
    done

    mark_failed "$num"
    echo -e "${RED}[Prompt ${num}] All ${MAX_RETRIES} attempts failed${NC}"
    return 1
}

# ═══════════════════════════════════════════════════════════════════════════════
# GIT FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════════

do_git_push() {
    echo ""
    echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}Committing and pushing changes to GitHub...${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"

    cd "${SCRIPT_DIR}"

    # Check if there are changes
    if git diff --quiet && git diff --cached --quiet && [[ -z "$(git ls-files --others --exclude-standard)" ]]; then
        echo -e "${YELLOW}No changes to commit${NC}"
        return 0
    fi

    # Stage all changes in audit directory
    git add -A

    # Build commit message
    local prompts_completed=""
    for num in $CHECKPOINT_COMPLETED; do
        prompts_completed="${prompts_completed}
- Prompt ${num}: ${DESCRIPTIONS[$num]}"
    done

    git commit -m "$(cat <<EOF
docs: Automated audit run - $(date +"%Y-%m-%d %H:%M")

Run ID: ${CHECKPOINT_RUN_ID}
Prompts completed:${prompts_completed}

See individual CHANGELOG.md files for details.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>
EOF
)"

    local current_branch
    current_branch=$(git branch --show-current)

    if git push origin "${current_branch}"; then
        echo -e "${GREEN}Successfully pushed to GitHub (branch: ${current_branch})${NC}"
    else
        echo -e "${RED}Failed to push to GitHub${NC}"
        return 1
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN EXECUTION
# ═══════════════════════════════════════════════════════════════════════════════

# Handle status mode
if $STATUS_MODE; then
    show_status
    exit 0
fi

# Handle reset mode
if $RESET_MODE; then
    echo -e "${YELLOW}Clearing checkpoint...${NC}"
    clear_checkpoint
    echo -e "${GREEN}Checkpoint cleared. Starting fresh.${NC}"
fi

# Load existing checkpoint
load_checkpoint

# Handle resume mode
if $RESUME_MODE; then
    if [[ -z "$CHECKPOINT_RUN_ID" ]]; then
        echo -e "${RED}No checkpoint to resume from. Starting fresh run.${NC}"
        RESUME_MODE=false
    else
        echo -e "${CYAN}Resuming run: ${CHECKPOINT_RUN_ID}${NC}"
        START=$CHECKPOINT_START
        END=$CHECKPOINT_END
    fi
fi

# Initialize new run if not resuming
if ! $RESUME_MODE || [[ -z "$CHECKPOINT_RUN_ID" ]]; then
    CHECKPOINT_RUN_ID=$(date +"%Y%m%d-%H%M%S")
    CHECKPOINT_START=$START
    CHECKPOINT_END=$END
    CHECKPOINT_COMPLETED=""
    CHECKPOINT_FAILED=""
    CHECKPOINT_IN_PROGRESS=""
    save_checkpoint
fi

# Display header
echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║     AISdb-Lite Audit Runner - $(date +"%Y-%m-%d %H:%M")            ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "Run ID:     ${CYAN}${CHECKPOINT_RUN_ID}${NC}"
echo -e "Repository: ${YELLOW}${REPO_ROOT}${NC}"
echo -e "Prompts:    ${YELLOW}${START} through ${END}${NC}"
echo -e "Retries:    ${YELLOW}${MAX_RETRIES} per prompt${NC}"
echo -e "Git:        ${YELLOW}$(if $DO_GIT; then echo 'Enabled'; else echo 'Disabled'; fi)${NC}"
echo -e "Log dir:    ${YELLOW}${LOG_DIR}${NC}"
if $RESUME_MODE; then
    echo -e "Mode:       ${CYAN}RESUME${NC}"
    echo -e "Completed:  ${GREEN}${CHECKPOINT_COMPLETED:-none}${NC}"
fi
echo ""

# Get pending prompts
pending_prompts=$(get_pending_prompts)

if [[ -z "$pending_prompts" ]]; then
    echo -e "${GREEN}All prompts already completed!${NC}"
    if $DO_GIT; then
        do_git_push
    fi
    clear_checkpoint
    exit 0
fi

echo -e "${BLUE}Prompts to run: ${YELLOW}${pending_prompts}${NC}"
echo ""

# Main execution loop
failed=0

for num in $pending_prompts; do
    if [[ -z "${DESCRIPTIONS[$num]}" ]]; then
        echo -e "${RED}Unknown prompt number: ${num}${NC}"
        ((failed++))
        continue
    fi

    if run_prompt_with_retry "$num"; then
        echo -e "${GREEN}✓ Prompt ${num} completed successfully${NC}"
    else
        echo -e "${RED}✗ Prompt ${num} failed after ${MAX_RETRIES} attempts${NC}"
        ((failed++))
    fi
    echo ""
done

# Git commit/push if all succeeded
if $DO_GIT; then
    if [[ $failed -eq 0 ]]; then
        do_git_push
        # Clear checkpoint on full success
        clear_checkpoint
    else
        echo ""
        echo -e "${YELLOW}Skipping git push due to prompt failures${NC}"
        echo -e "${CYAN}Run './run_audit.sh --resume' to retry failed prompts${NC}"
    fi
fi

# Final summary
echo ""
echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}Audit Complete!${NC}"
echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
echo ""
echo "Logs saved to: ${LOG_DIR}/"
echo ""

if [[ $failed -eq 0 ]]; then
    echo -e "${GREEN}All prompts completed successfully!${NC}"
else
    echo -e "${RED}${failed} prompt(s) failed.${NC}"
    echo ""
    echo "To retry failed prompts:"
    echo -e "  ${CYAN}./run_audit.sh --resume${NC}"
    echo ""
    echo "To check status:"
    echo -e "  ${CYAN}./run_audit.sh --status${NC}"
    echo ""
    echo "To start fresh:"
    echo -e "  ${CYAN}./run_audit.sh --reset${NC}"
fi

exit $failed
