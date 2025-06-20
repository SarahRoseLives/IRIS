#!/bin/bash

# Create a temporary buffer file
BUFFER=$(mktemp)

# Add the tree structure
echo "===== PROJECT TREE =====" > "$BUFFER"
tree >> "$BUFFER"

# Add Go file contents if any exist
GO_FILES=$(find . -type f -name "*.go")
if [[ -n "$GO_FILES" ]]; then
    echo -e "\n===== .go FILE CONTENTS =====" >> "$BUFFER"
    echo "$GO_FILES" | while read -r file; do
        echo -e "\n======${file#./}=======" >> "$BUFFER"
        cat "$file" >> "$BUFFER"
    done
fi

# Add Dart file contents if any exist
DART_FILES=$(find . -type f -name "*.dart")
if [[ -n "$DART_FILES" ]]; then
    echo -e "\n===== .dart FILE CONTENTS =====" >> "$BUFFER"
    echo "$DART_FILES" | while read -r file; do
        echo -e "\n======${file#./}=======" >> "$BUFFER"
        cat "$file" >> "$BUFFER"
    done
fi

# Copy to clipboard using xclip
xclip -selection clipboard < "$BUFFER"

# Optionally output a confirmation
echo "Copied project tree and .go/.dart files to clipboard."

# Clean up
rm "$BUFFER"
