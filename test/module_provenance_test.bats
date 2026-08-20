#!/usr/bin/env -S bats --jobs 16

# Module provenance: commands registered from a BU_MODULE_LIST preinit
# callback carry their owning module, core builtins are untagged, and the
# first-word dropdown metadata surfaces the module tag (only when more than
# one module is loaded).

setup() {
    load "test_helper/bats-assert/load.bash"
    load "test_helper/bats-support/load.bash"
    DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" >/dev/null 2>&1 && pwd )"
}

# Create a module fixture: one executable command script plus a uniquely-named
# preinit that registers ./commands as a command-search dir. Echoes the preinit
# path. The unique preinit basename matters: --__bu-once dedups by basename.
# $1 = module name, $2 = command script basename, $3 = optional namespace style
__make_module_fixture() {
    local name=$1
    local cmd=$2
    local ns_style=$3
    local dir="$BATS_TEST_TMPDIR/$name"
    mkdir -p "$dir/commands"
    printf '#!/usr/bin/env bash\necho hi\n' > "$dir/commands/$cmd.sh"
    chmod +x "$dir/commands/$cmd.sh"
    local import_args="+i -c ./commands"
    [[ -n "$ns_style" ]] && import_args+=" -ns $ns_style"
    {
        echo '#!/usr/bin/env bash'
        echo 'source "$BU_NULL"'
        echo 'bu_pushd_current "$BASH_SOURCE"'
        echo "bu import-environment $import_args"
        echo 'bu_popd_silent'
    } > "$dir/$name-preinit.sh"
    echo "$dir/$name-preinit.sh"
}

function test_module_provenance_property_and_dir_map { #@test
    local preinit
    preinit=$(__make_module_fixture moda get-alpha-thing)
    run bash -c '
        export BU_TOP_LEVEL_MODULE=moda
        export BU_MODULE_LIST="moda:0.1.0:$1;"
        source "$2"/bu_entrypoint.sh >/dev/null 2>&1
        echo "FIXTURE_MODULE=$(bu get-command --format jsonl 2>/dev/null | jq -r "select(.name == \"get-alpha-thing\") | .module")"
        echo "CORE_MODULE=$(bu get-command --format jsonl 2>/dev/null | jq -r "select(.name == \"get-command\") | .module")"
        echo "DIR_MAP_COUNT=$(printf "%s\n" "${!BU_COMMAND_SEARCH_DIR_MODULE[@]}" | grep -c .)"
        echo "DIR_MAP_VALUE=$(printf "%s\n" "${BU_COMMAND_SEARCH_DIR_MODULE[@]}" | sort -u)"
    ' _ "$preinit" "$DIR"/..
    assert_success
    assert_line "FIXTURE_MODULE=moda"
    assert_line "CORE_MODULE="
    assert_line "DIR_MAP_COUNT=1"
    assert_line "DIR_MAP_VALUE=moda"
}

function test_completion_module_tags_two_modules { #@test
    local pre_a pre_b
    pre_a=$(__make_module_fixture moda get-alpha-thing)
    pre_b=$(__make_module_fixture modb get-beta-thing)
    run bash -c '
        export BU_TOP_LEVEL_MODULE=moda
        export BU_MODULE_LIST="moda:0.1.0:$1;modb:0.1.0:$2;"
        source "$3"/bu_entrypoint.sh >/dev/null 2>&1
        COMPREPLY=()
        COMP_CWORD=1
        COMP_WORDS=("$BU_CLI_COMMAND_NAME" "")
        COMP_LINE="$BU_CLI_COMMAND_NAME "
        BU_AUTOCOMPLETE_ACCEPT_ANSI_COLORS=true
        __bu_autocomplete_completion_func_cli "$BU_CLI_COMMAND_NAME" "" ""
        strip() { sed -r "s/\x1B\[[0-9;]*[mGK]//g; s/\x1B\(B//g"; }
        for i in "${!COMPREPLY[@]}"
        do
            c=$(printf "%s" "${COMPREPLY[i]}" | strip)
            case "$c" in
            get-alpha-thing|get-beta-thing|get-command)
                m=$(printf "%s" "${BU_COMPREPLY_METADATA[i]}" | strip)
                echo "ROW:$c=$m"
                ;;
            esac
        done
    ' _ "$pre_a" "$pre_b" "$DIR"/..
    assert_success
    assert_line "ROW:get-alpha-thing=execute [moda]"
    assert_line "ROW:get-beta-thing=execute [modb]"
    assert_line "ROW:get-command=source [bu]"
}

function test_completion_no_module_tag_single_module { #@test
    local preinit
    preinit=$(__make_module_fixture moda get-alpha-thing)
    run bash -c '
        export BU_TOP_LEVEL_MODULE=moda
        export BU_MODULE_LIST="moda:0.1.0:$1;"
        source "$2"/bu_entrypoint.sh >/dev/null 2>&1
        COMPREPLY=()
        COMP_CWORD=1
        COMP_WORDS=("$BU_CLI_COMMAND_NAME" "")
        COMP_LINE="$BU_CLI_COMMAND_NAME "
        BU_AUTOCOMPLETE_ACCEPT_ANSI_COLORS=true
        __bu_autocomplete_completion_func_cli "$BU_CLI_COMMAND_NAME" "" ""
        strip() { sed -r "s/\x1B\[[0-9;]*[mGK]//g; s/\x1B\(B//g"; }
        for i in "${!COMPREPLY[@]}"
        do
            c=$(printf "%s" "${COMPREPLY[i]}" | strip)
            case "$c" in
            get-alpha-thing) m=$(printf "%s" "${BU_COMPREPLY_METADATA[i]}" | strip); echo "FIXTURE_META=$m" ;;
            get-command)     m=$(printf "%s" "${BU_COMPREPLY_METADATA[i]}" | strip); echo "CORE_META=$m" ;;
            esac
        done
    ' _ "$preinit" "$DIR"/..
    assert_success
    assert_line "FIXTURE_META=execute"
    assert_line "CORE_META=source"
}

# ===========================================================================
# Namespace defaults to the module
# ===========================================================================

function test_namespace_defaults_to_module_scoped_completion { #@test
    local pre_a pre_b
    pre_a=$(__make_module_fixture moda get-alpha-thing)
    pre_b=$(__make_module_fixture modb get-beta-thing)
    run bash -c '
        export BU_TOP_LEVEL_MODULE=moda
        export BU_MODULE_LIST="moda:0.1.0:$1;modb:0.1.0:$2;"
        source "$3"/bu_entrypoint.sh >/dev/null 2>&1
        echo "ALPHA_NS=$(bu get-command --format jsonl 2>/dev/null | jq -r "select(.name == \"get-alpha-thing\") | .namespace")"
        echo "BETA_NS=$(bu get-command --format jsonl 2>/dev/null | jq -r "select(.name == \"get-beta-thing\") | .namespace")"
        COMPREPLY=(); COMP_CWORD=1; COMP_WORDS=(bu ":moda:"); COMP_LINE="bu :moda:"
        __bu_autocomplete_completion_func_cli "$BU_CLI_COMMAND_NAME" ":moda:" ""
        strip() { sed -r "s/\x1B\[[0-9;]*[mGK]//g; s/\x1B\(B//g"; }
        for r in "${COMPREPLY[@]}"; do echo "MODA_ROW=$(printf "%s" "$r" | strip)"; done
    ' _ "$pre_a" "$pre_b" "$DIR"/..
    assert_success
    assert_line "ALPHA_NS=moda"
    assert_line "BETA_NS=modb"
    assert_line "MODA_ROW=:moda:get-alpha-thing"
    refute_line "MODA_ROW=:moda:get-beta-thing"
}

function test_prefix_converter_keeps_filename_namespace { #@test
    local preinit
    preinit=$(__make_module_fixture moda myns-get-alpha-thing prefix)
    run bash -c '
        export BU_TOP_LEVEL_MODULE=moda
        export BU_MODULE_LIST="moda:0.1.0:$1;"
        source "$2"/bu_entrypoint.sh >/dev/null 2>&1
        echo "RECORD=$(bu get-command --format jsonl 2>/dev/null | jq -c "select(.name == \"get-alpha-thing\") | {module,namespace}")"
    ' _ "$preinit" "$DIR"/..
    assert_success
    assert_line 'RECORD={"module":"moda","namespace":"myns"}'
}

function test_namespace_row_metadata_count_and_nospace { #@test
    local pre_a pre_b
    pre_a=$(__make_module_fixture moda get-alpha-thing)
    pre_b=$(__make_module_fixture modb get-beta-thing)
    run bash -c '
        export BU_TOP_LEVEL_MODULE=moda
        export BU_MODULE_LIST="moda:0.1.0:$1;modb:0.1.0:$2;"
        source "$3"/bu_entrypoint.sh >/dev/null 2>&1
        COMPREPLY=(); COMP_CWORD=1; COMP_WORDS=(bu ":"); COMP_LINE="bu :"
        BU_AUTOCOMPLETE_ACCEPT_ANSI_COLORS=true
        BU_COMPOPT_CURRENT_COMPLETION_OPTIONS=()
        BU_COMPOPT_DYNAMIC_COMPLETION_OPTIONS=()
        __bu_autocomplete_completion_func_cli "$BU_CLI_COMMAND_NAME" ":" ""
        strip() { sed -r "s/\x1B\[[0-9;]*[mGK]//g; s/\x1B\(B//g"; }
        for i in "${!COMPREPLY[@]}"
        do
            c=$(printf "%s" "${COMPREPLY[i]}" | strip)
            [[ "$c" == :moda: ]] && echo "MODA_META=$(printf "%s" "${BU_COMPREPLY_METADATA[i]}" | strip)"
        done
        echo "NOSPACE=${BU_COMPOPT_DYNAMIC_COMPLETION_OPTIONS[nospace]:-EMPTY}"
    ' _ "$pre_a" "$pre_b" "$DIR"/..
    assert_success
    assert_line "MODA_META=namespace (1 command)"
    assert_line "NOSPACE=-o"
}

function test_scoped_rows_resolve_type_module_no_nospace { #@test
    local pre_a pre_b
    pre_a=$(__make_module_fixture moda get-alpha-thing)
    pre_b=$(__make_module_fixture modb get-beta-thing)
    run bash -c '
        export BU_TOP_LEVEL_MODULE=moda
        export BU_MODULE_LIST="moda:0.1.0:$1;modb:0.1.0:$2;"
        source "$3"/bu_entrypoint.sh >/dev/null 2>&1
        COMPREPLY=(); COMP_CWORD=1; COMP_WORDS=(bu ":moda:"); COMP_LINE="bu :moda:"
        BU_AUTOCOMPLETE_ACCEPT_ANSI_COLORS=true
        BU_COMPOPT_CURRENT_COMPLETION_OPTIONS=()
        BU_COMPOPT_DYNAMIC_COMPLETION_OPTIONS=()
        __bu_autocomplete_completion_func_cli "$BU_CLI_COMMAND_NAME" ":moda:" ""
        strip() { sed -r "s/\x1B\[[0-9;]*[mGK]//g; s/\x1B\(B//g"; }
        for i in "${!COMPREPLY[@]}"
        do
            c=$(printf "%s" "${COMPREPLY[i]}" | strip)
            [[ "$c" == :moda:get-alpha-thing ]] && echo "ROW_META=$(printf "%s" "${BU_COMPREPLY_METADATA[i]}" | strip)"
        done
        echo "NOSPACE=${BU_COMPOPT_DYNAMIC_COMPLETION_OPTIONS[nospace]:-EMPTY}"
    ' _ "$pre_a" "$pre_b" "$DIR"/..
    assert_success
    assert_line "ROW_META=execute [moda]"
    assert_line "NOSPACE=EMPTY"
}
