#!/usr/bin/env bash

assert_contains() {
  local file="$1"
  local needle="$2"
  grep -Fq -- "$needle" "$file" || {
    echo "missing expected text in $file: $needle" >&2
    exit 1
  }
}

assert_not_contains() {
  local file="$1"
  local needle="$2"
  if grep -Fq -- "$needle" "$file"; then
    echo "unexpected text in $file: $needle" >&2
    exit 1
  fi
}

setup_repo() {
  local workdir="$1"
  local task="$2"
  local origin="${workdir}-origin.git"
  git init -q --bare "$origin"
  git clone -q "$origin" "$workdir"
  (
    cd "$workdir"
    git checkout -q -b main
    git config user.email "test@example.com"
    git config user.name "Harness Test"
    echo root > README.md
    echo baseline-a > a.txt
    echo baseline-b > b.txt
    git add README.md a.txt b.txt
    git commit -q -m "initial"
    git push -q -u origin main
    mkdir -p ".harness/$task"
  )
}
