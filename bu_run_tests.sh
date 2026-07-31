#!/usr/bin/env bash
case "${BASH_SOURCE}" in
*/*) cd "${BASH_SOURCE%/*}";;
*);;
esac

# Source the activate script with test environment
source ./activate -t

# Run all test files with intra-file parallel execution.
# CI uses a matrix strategy (one job per file, see .github/workflows/bats-tests.yml).
# For local runs this runs all files in one go; pass specific files to narrow the scope.
if (($#)); then
    bats --jobs "$((($(nproc) + 1) / 2))" "$@"
else
    # Only BashTab's own test files, not bats-assert/bats-support submodule tests
    bats --jobs "$((($(nproc) + 1) / 2))" ./test/test.bats ./test/out_test.bats ./test/config_test.bats ./test/smoke_test.bats ./test/new_commands_test.bats ./test/api_contract_test.bats ./test/cli_rename_test.bats ./test/first_test.bats ./test/fzf_dims_test.bats ./test/integration_test.bats ./test/npm_test.bats ./test/parse_bash_test.bats ./test/ts_test.bats
fi
