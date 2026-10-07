#!/bin/sh
# Classify a pull request or push for the CI workflow. Writes code, ui, and host
# to GITHUB_OUTPUT. code selects test and c-smoke; ui also selects golden;
# host selects the Windows and macOS jobs. A manual run exercises the code path
# including the selected native machines.
set -eu

if [ "$GITHUB_EVENT_NAME" = "workflow_dispatch" ]; then
    {
        echo "code=true"
        echo "ui=true"
        echo "host=true"
    } >>"$GITHUB_OUTPUT"
    exit 0
fi

code=false
ui=false
host=false

list_files() {
    if [ "$GITHUB_EVENT_NAME" = "pull_request" ]; then
        git diff --name-only "$PR_BASE...$PR_HEAD"
        return
    fi
    if [ "$GITHUB_EVENT_NAME" = "push" ]; then
        zeros=0000000000000000000000000000000000000000
        if [ "$PUSH_BEFORE" = "$zeros" ]; then
            git ls-files
        else
            git diff --name-only "$PUSH_BEFORE" "$GITHUB_SHA"
        fi
        return
    fi
    git ls-files
}

files=$(list_files)
while IFS= read -r file; do
    if [ -z "$file" ]; then
        continue
    fi
    case "$file" in
    libs/ui/* | tests/golden/*) ui=true ;;
    esac
    case "$file" in
    *.zig | *.zon | api/* | build/* | examples/* | tests/* | third_party/* | .github/*)
        code=true
        host=true
        ;;
    docs/* | *.md | *.mdx | apps/user-docs/* | LICENSE | .gitignore | .gitattributes)
        ;;
    *)
        # Unknown executable/configuration inputs conservatively select both native jobs.
        code=true
        host=true
        ;;
    esac
done <<EOF
$files
EOF

{
    echo "code=$code"
    echo "ui=$ui"
    echo "host=$host"
} >>"$GITHUB_OUTPUT"
