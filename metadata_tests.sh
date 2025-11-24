#!/usr/bin/env bash

set -euo pipefail

# Test suite for metadata script, intended to be sourced and executed via metadata --test

metadata_run_tests() {
	local test_fails=0
	local ret=0

	if ! is_root; then
		note "Running without root privileges - skipping ownership-sensitive checks"
	fi

	# Mute progress output during tests except where explicitly required
	export MUTE_PROGRESS=1

	# Test utilities
	export TEST_DIR=$(mktemp -d)
	export BACKUP_DIR=$(mktemp -d)
	export RESTORE_DIR=$(mktemp -d)

	trap 'rm -rf "$TEST_DIR" "$BACKUP_DIR" "$RESTORE_DIR"' EXIT

	build_base_fixture

	(
		test_backup_metadata || ret=$?
		((test_fails+=ret)) || true

		test_restore_metadata || ret=$?
		((test_fails+=ret)) || true

		test_diff_metadata || ret=$?
		((test_fails+=ret)) || true

		test_excludes || ret=$?
		((test_fails+=ret)) || true

		test_excludes_component_match || ret=$?
		((test_fails+=ret)) || true

		test_error_handler || ret=$?
		((test_fails+=ret)) || true

		test_progress_indication || ret=$?
		((test_fails+=ret)) || true

		test_cli_validation || ret=$?
		((test_fails+=ret)) || true

		test_process_path || ret=$?
		((test_fails+=ret)) || true

		test_copy_metadata_failure || ret=$?
		((test_fails+=ret)) || true

		if [ $test_fails -eq 0 ]; then
			green "All tests passed!"
		else
			red "$test_fails tests failed!"
		fi
		return $test_fails
	) 2>&1 | grep -v "Not running as root"

	local test_status=${PIPESTATUS[0]}

	return $test_status
}

# Create a baseline directory structure used by multiple tests
build_base_fixture() {
	mkdir -p "$TEST_DIR/dir1/subdir1/subdir2"
	$TOUCH_CMD "$TEST_DIR/dir1/file1"
	$TOUCH_CMD "$TEST_DIR/dir1/file2"
	$TOUCH_CMD "$TEST_DIR/dir1/subdir1/subdir2/file3"
	ln -s "$TEST_DIR/dir1/file1" "$TEST_DIR/dir1/symlink1"
	$CHMOD_CMD 600 "$TEST_DIR/dir1/file1"
	$CHMOD_CMD 755 "$TEST_DIR/dir1/file2"
	$CHMOD_CMD 644 "$TEST_DIR/dir1/subdir1/subdir2/file3"
	$TOUCH_CMD -t 202001010000 "$TEST_DIR/dir1/file1"
	$TOUCH_CMD -t 202002020000 "$TEST_DIR/dir1/file2"
	$TOUCH_CMD -t 202003030000 "$TEST_DIR/dir1/subdir1/subdir2/file3"
}

test_backup_metadata() {
	debug "Testing backup creation..."

	backup_metadata "$TEST_DIR" "$BACKUP_DIR"

	local failures=0
	for file in "dir1/file1" "dir1/file2" "dir1/subdir1/subdir2/file3"; do
		if [ ! -e "$BACKUP_DIR/$file" ]; then
			error "$(basename "$file") not created in backup"
			((failures++)) || true
		fi
	done

	[ ! -d "$BACKUP_DIR" ] && error "Backup directory not created" && return 1
	[ -L "$BACKUP_DIR/dir1/symlink1" ] && error "Symlink was copied but should have been ignored" && return 1

	[ "$($STAT_CMD --format=%a "$BACKUP_DIR/dir1/file1")" = "600" ] || { error "'600' != '$($STAT_CMD --format=%a "$BACKUP_DIR/dir1/file1")'"; ((failures++)) || true; }
	[ "$($STAT_CMD --format=%a "$BACKUP_DIR/dir1/file2")" = "755" ] || { error "'755' != '$($STAT_CMD --format=%a "$BACKUP_DIR/dir1/file2")'"; ((failures++)) || true; }
	[ "$($STAT_CMD --format=%a "$BACKUP_DIR/dir1/subdir1/subdir2/file3")" = "644" ] || { error "'644' != '$($STAT_CMD --format=%a "$BACKUP_DIR/dir1/subdir1/subdir2/file3")'"; ((failures++)) || true; }

	return $failures
}

test_restore_metadata() {
	debug "Testing metadata restoration..."
	local ret=0

	backup_metadata "$TEST_DIR" "$BACKUP_DIR"
	mkdir -p "$RESTORE_DIR/dir1/subdir1/subdir2"
	$TOUCH_CMD "$RESTORE_DIR/dir1/file1"
	$TOUCH_CMD "$RESTORE_DIR/dir1/file2"
	$TOUCH_CMD "$RESTORE_DIR/dir1/subdir1/subdir2/file3"
	$CHMOD_CMD 777 "$RESTORE_DIR/dir1/file1"
	$CHMOD_CMD 644 "$RESTORE_DIR/dir1/file2"

	restore_metadata "$BACKUP_DIR" "$RESTORE_DIR"
	diff_metadata "$TEST_DIR" "$RESTORE_DIR" || ret=$?

	return $ret
}

test_diff_metadata() {
	debug "Testing metadata diff..."
	local failures=0
	local ret=0

	backup_metadata "$TEST_DIR" "$BACKUP_DIR" || { error "Failed to create backup for diff test"; ((ret++)) || true; }
	diff_metadata "$TEST_DIR" "$BACKUP_DIR" || ret=$?
	if [ $ret -ne 0 ]; then
		error "Identical trees reported differences"
		((failures++)) || true
	fi

	$CHMOD_CMD 777 "$BACKUP_DIR"/dir1/file1
	diff_metadata "$TEST_DIR" "$BACKUP_DIR" > /dev/null || ret=$?
	if [ $ret -eq 0 ]; then
		error "Diff did not detect permission changes"
		((failures++)) || true
	fi

	return $failures
}

test_excludes() {
	local failures=0
	mkdir -p "$TEST_DIR"/{src,node_modules,target}
	$TOUCH_CMD "$TEST_DIR"/{src/main.rs,node_modules/foo,target/debug}

	EXCLUDES="target node_modules" backup_metadata "$TEST_DIR" "$BACKUP_DIR"

	if [ -e "$BACKUP_DIR/node_modules" ]; then
		error "node_modules was not excluded"
		((failures++)) || true
	fi

	if [ -e "$BACKUP_DIR/target" ]; then
		error "target was not excluded"
		((failures++)) || true
	fi

	if [ ! -e "$BACKUP_DIR/src/main.rs" ]; then
		error "src/main.rs was incorrectly excluded"
		((failures++)) || true
	fi

	return $failures
}

# Ensure exclude patterns match path components, not substrings
test_excludes_component_match() {
	local failures=0
	mkdir -p "$TEST_DIR/attempt"
	$TOUCH_CMD "$TEST_DIR/attempt/file"

	EXCLUDES="tmp" backup_metadata "$TEST_DIR" "$BACKUP_DIR"

	if [ ! -e "$BACKUP_DIR/attempt/file" ]; then
		error "Component-based exclude incorrectly filtered 'attempt'"
		((failures++)) || true
	fi

	return $failures
}

test_error_handler() {
	debug "Testing error handler..."
	local error_output=$(mktemp)

	if DEBUG=1 "$0" error_test 2> "$error_output"; then
		error "Error handler test failed - command succeeded when it should have failed"
		rm "$error_output"
		return 1
	fi

	local expected_patterns=(
		"Error in.*at.*metadata.*exit code:"
		"Command that failed:"
		"Call trace:"
		"[[:space:]]*->.*at.*metadata:"
	)

	local failed=0
	for pattern in "${expected_patterns[@]}"; do
		if ! grep -E "$pattern" "$error_output" >/dev/null; then
			error "Error handler output missing pattern: $pattern"
			failed=1
		fi
	done

	rm "$error_output"

	return $failed
}

test_progress_indication() {
	debug "Testing progress indication..."
	local failures=0
	local progress_output=$(mktemp)

	local old_mute_progress="${MUTE_PROGRESS:-}"
	unset MUTE_PROGRESS

	mkdir -p "$TEST_DIR/progress_test"
	$TOUCH_CMD "$TEST_DIR/progress_test/file1"
	$TOUCH_CMD "$TEST_DIR/progress_test/file2"

	UPDATE_INTERVAL=1 backup_metadata "$TEST_DIR/progress_test" "$BACKUP_DIR" > "$progress_output" 2>&1

	if ! grep -q "Progress: 33% (1/3)" "$progress_output"; then
		error "Expected 33% progress message not found"
		((failures++))
	fi

	if ! grep -q "Progress: 100% (3/3)" "$progress_output"; then
		error "Expected 100% progress message not found"
		((failures++))
	fi

	rm -f "$progress_output"
	MUTE_PROGRESS="$old_mute_progress"

	return $failures
}

test_cli_validation() {
	debug "Testing CLI argument validation..."
	local failures=0
	local output

	set +e

	output=$("$0" backup 2>&1)
	if [[ $? -eq 0 ]]; then
		error "backup without args should fail"
		((failures++))
	fi

	output=$("$0" diff one 2>&1)
	if [[ $? -eq 0 ]]; then
		error "diff with one arg should fail"
		((failures++))
	fi

	set -e
	return $failures
}

test_process_path() {
	debug "Testing process_path timestamp replacement..."
	local year=$($DATE_CMD +%Y)
	local out
	local old_timestamp="${TIMESTAMP:-}"
	TIMESTAMP=%Y
	out=$(process_path "/tmp/%Y/%timestamp")
	TIMESTAMP="$old_timestamp"

	if [[ "$out" != "/tmp/$year/$year" ]]; then
		error "process_path did not replace formats correctly: $out"
		return 1
	fi

	return 0
}

test_copy_metadata_failure() {
	debug "Testing copy_metadata failure propagation..."
	local failures=0
	local missing_source="$TEST_DIR/nonexistent"
	local target="$TEST_DIR/target"

	touch "$target"
	FAIL_COUNT=0
	FAIL_LOG=""
	copy_metadata "$missing_source" "$target" 2>/dev/null || true
	if [ $FAIL_COUNT -eq 0 ]; then
		error "copy_metadata did not record failure for missing source"
		((failures++))
	fi
	if [ -z "$FAIL_LOG" ] || [ ! -s "$FAIL_LOG" ]; then
		error "Failure log not created or empty"
		((failures++))
	fi

	return $failures
}

# Allow running this file directly for debugging
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	metadata_run_tests
fi
