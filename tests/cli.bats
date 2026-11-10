#!/usr/bin/env bats
# work.sh as a whole: the dispatcher and the commands that need no Docker.

load helpers

@test "help lists the commands" {
  run "$REPO/work.sh" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"./work.sh connect"* ]]
  [[ "$output" == *"./work.sh windows <cmd>"* ]]
}

@test "unknown commands fail with a pointer to help" {
  run "$REPO/work.sh" frobnicate
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown command: frobnicate"* ]]
}

@test "paths works before setup and shows the isolated folders" {
  run "$REPO/work.sh" paths
  [ "$status" -eq 0 ]
  [[ "$output" == *"~/.config/work/env"* ]]
  [[ "$output" == *"~/shared"* ]]
}

@test "commands that need the env file point to setup" {
  run "$REPO/work.sh" connect
  [ "$status" -eq 1 ]
  [[ "$output" == *"./work.sh setup"* ]]
}

@test "subcommand help needs no env file" {
  run "$REPO/work.sh" windows
  [ "$status" -eq 0 ]
  [[ "$output" == *"windows bootstrap"* ]]
  run "$REPO/work.sh" linux
  [ "$status" -eq 0 ]
  [[ "$output" == *"linux rebuild"* ]]
}
