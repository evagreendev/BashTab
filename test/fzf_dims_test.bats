#!/usr/bin/env bats

# Unit tests for __bu_fzf_compute_dimensions — fzf dropdown positioning math.
# Does NOT require tree-sitter or bash-completion.

setup() {
    DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" >/dev/null 2>&1 && pwd )"
    # Source only the function, not the whole entrypoint
    # Extract and source __bu_fzf_compute_dimensions from the autocomplete lib
    source <(sed -n '/^__bu_fzf_compute_dimensions()/,/^}$/{p; /^}$/q}' "$DIR"/../lib/core/bu_core_autocomplete.sh)
}

# Helper: call __bu_fzf_compute_dimensions and assert results
# Usage: assert_dims COLUMNS ANCHOR WORD_LEN BASE_WID PREVIEW_WID \
#                EXPECTED_LEFT EXPECTED_RMARGIN EXPECTED_BOX
assert_dims() {
    local cols=$1 anchor=$2 wlen=$3 bw=$4 pw=$5
    local exp_left=$6 exp_rmargin=$7 exp_box=$8
    __bu_fzf_compute_dimensions "$cols" "$anchor" "$wlen" "$bw" "$pw"
    local left=${BU_RET[0]} rmarg=${BU_RET[1]} box=${BU_RET[2]}
    local ok=true
    (( left != exp_left )) && { echo "FAIL: left_pos expected $exp_left got $left" >&2; ok=false; }
    (( rmarg != exp_rmargin )) && { echo "FAIL: right_margin expected $exp_rmargin got $rmarg" >&2; ok=false; }
    (( box != exp_box )) && { echo "FAIL: box_length expected $exp_box got $box" >&2; ok=false; }
    "$ok"
}

# ===========================================================================
# Plenty of space — everything fits
# ===========================================================================

function test_fits_wide_80_no_preview { #@test
    # 80 cols, anchor 0, word=3, base=60, no preview
    # min=63; right=63≤80; left=0; box=63-0-0-3=60; rmarg=80-63=17
    assert_dims 80 0 3 60 0 0 17 60
}

function test_fits_wide_80_with_preview { #@test
    # 80 cols, anchor=0, word=3, base=60, preview=40
    # min=103; right=80(clamp); left=max(80-103,0)=0; right=0+103=80(clamp); box=80-0-40-5=35
    assert_dims 80 0 3 60 40 0 0 35
}

function test_fits_wide_120 { #@test
    # 120 cols, anchor 10, word=5, base=60, preview=40
    # min=60+40+5=105; right=10+105=115≤120; left=10; box=115-10-40-5=60
    assert_dims 120 10 5 60 40 10 5 60
}

function test_fits_200 { #@test
    # Huge terminal, no constraint
    # min=60+40+5=105; right=20+105=125≤200; left=20; box=125-20-40-5=60
    assert_dims 200 20 5 60 40 20 75 60
}

# ===========================================================================
# Right-edge overflow — pushes left
# ===========================================================================

function test_overflow_right { #@test
    # 80 cols, anchor=50, word=0, base=60, no preview
    # min=60+0+0=60; right=50+60=110>80→80; left=80-60=20; box=80-20-0-3=57
    assert_dims 80 50 0 60 0 20 0 57
}

function test_overflow_right_small_terminal { #@test
    # 80 cols, anchor=60, word=10, base=60, preview=40
    # min=60+40+10=110; right=60+110=170>80→80; left=80-110=-30→0; right=0+110=110>80→80
    # watch order: left=0, right_pos=0+110=110>80→80, box=80-0-40-5=35
    assert_dims 80 60 10 60 40 0 0 35
}

# ===========================================================================
# Very small terminal — everything squeezed
# ===========================================================================

function test_squeeze_tight { #@test
    # 40 cols is tiny. anchor=0, word=0, base=60, no preview
    # min=60; right=0+60=60>40→40; left=40-60=-20→0; right=0+60=60>40→40
    # box=40-0-0-3=37
    assert_dims 40 0 0 60 0 0 0 37
}

# ===========================================================================
# Clean: negative anchor clamped
# ===========================================================================

function test_negative_anchor { #@test
    # anchor=-5 (can happen with PS1 offset wrapping)
    # clamps to 0
    assert_dims 80 -5 3 60 0 0 17 60
}

# ===========================================================================
# Box length floor (never below 20)
# ===========================================================================

function test_box_length_floor { #@test
    # 40 cols, anchor=35, word=0, base=60, preview=40
    # min=100; right=35+100=135>40→40; left=40-100=-60→0; right=0+100=100>40→40
    # box=40-0-40-5=-5; floor to 20
    assert_dims 40 35 0 60 40 0 0 20
}

# ===========================================================================
# Consistency properties (property-based)
# ===========================================================================

function test_invariants_no_preview { #@test
    local cols anchor wlen base pw left rmarg box
    for cols in 60 80 100 120 200; do
        for anchor in 0 10 30 50 70; do
            for wlen in 0 3 10 30; do
                for base in 40 60 80; do
                    __bu_fzf_compute_dimensions "$cols" "$anchor" "$wlen" "$base" 0
                    left=${BU_RET[0]}; rmarg=${BU_RET[1]}; box=${BU_RET[2]}
                    # invariants
                    (( left >= 0 )) || { echo "FAIL: left=$left < 0 cols=$cols"; return 1; }
                    (( rmarg >= 0 )) || { echo "FAIL: rmarg=$rmarg < 0"; return 1; }
                    (( box >= 20 )) || { echo "FAIL: box=$box < 20"; return 1; }
                    (( left + box + 3 + rmarg <= cols )) || {
                        echo "FAIL: overflow $cols cols=$cols left=$left box=$box rmarg=$rmarg sum=$((left+box+3+rmarg))"
                        return 1
                    }
                done
            done
        done
    done
}

function test_invariants_with_preview { #@test
    local cols anchor wlen base pw left rmarg box
    for cols in 80 100 120 200; do
        for anchor in 0 5 20 50 70; do
            for base in 60 80; do
                __bu_fzf_compute_dimensions "$cols" "$anchor" 5 "$base" 40
                left=${BU_RET[0]}; rmarg=${BU_RET[1]}; box=${BU_RET[2]}
                (( left >= 0 )) || { echo "FAIL: left=$left < 0 cols=$cols"; return 1; }
                (( rmarg >= 0 )) || { echo "FAIL: rmarg=$rmarg < 0"; return 1; }
                (( box >= 20 )) || { echo "FAIL: box=$box < 20"; return 1; }
                (( left + box + 5 + rmarg <= cols )) || {
                    echo "FAIL: overflow $cols cols=$cols left=$left box=$box rmarg=$rmarg"
                    return 1
                }
            done
        done
    done
}

# ===========================================================================
# Real-world scenarios
# ===========================================================================

function test_real_ls_80col { #@test
    # "ls " at 80-col terminal, PS1 occupies 20 cols, cursor at col 23
    # replacing empty word (0 len), anchor = (20-2+23-0) = 41
    # base=60, no preview (metadata fits)
    # min=60; right=41+60=101>80→80; left=80-60=20; box=80-20-0-3=57; rmarg=0
    assert_dims 80 41 0 60 0 20 0 57
}

function test_real_ls_120col { #@test
    # "ls " at 120-col, PS1=15, cursor=18, word=0, base=60, no preview
    # anchor = (15-2+18-0) = 31
    # min=60; right=31+60=91≤120; left=31; box=91-31-0-3=57; rmarg=29
    assert_dims 120 31 0 60 0 31 29 57
}

function test_real_variable_meta_fits { #@test
    # "echo $HO" at 100-col, cursor at 8, word="$HO"=3, anchor=(15-2+8-3)=18
    # base=60 (variable names are short), no preview
    # min=63; right=18+63=81≤100; left=18; box=81-18-0-3=60; rmarg=19
    assert_dims 100 18 3 60 0 18 19 60
}
