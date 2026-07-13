#!/bin/sh
# Command-level regression tests for *Assemble.
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
fixtures="$root/testcode/command"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM

fail()
{
    echo "FAIL: $*" >&2
    exit 1
}

check_hex()
{
    file=$1
    expected=$2
    actual=$(od -An -tx1 -v "$file" | tr -d ' \n')
    [ "$actual" = "$expected" ] || fail "$file: expected $expected, got $actual"
}

run_selector_checks()
{
    arch=$1
    binary="$root/aif$arch/Assemble,ff8"
    riscos_arch=
    [ "$arch" = 64 ] && riscos_arch=--64
    riscos-build-run $riscos_arch "$binary" "$fixtures/nop,fff" \
        --command "run Assemble -cpu 6502 -input nop -output o6502" \
        --command "run Assemble -cpu 65c02 -input nop -output o65c02" \
        --command "run Assemble -cpu 65c816 -input nop -output o65c816" \
        --command "run Assemble -cpu 6809 -input nop -output o6809" \
        --command "run Assemble -cpu z80 -input nop -output oz80" \
        --command "run Assemble -cpu x86-64 -input nop -output ox86" \
        --command "run Assemble -cpu arm32 -input nop -output oarm" \
        --command "run Assemble -cpu arm32-fpa -input nop -output ofpa" \
        --command "run Assemble -cpu arm32-vfp -input nop -output ovfp" \
        --return-file ovfp --return-to "$work/selectors-$arch" >/dev/null
    check_hex "$work/selectors-$arch" 00f020e3
}

run_two_pass_checks()
{
    arch=$1
    binary="$root/aif$arch/Assemble,ff8"
    riscos_arch=
    [ "$arch" = 64 ] && riscos_arch=--64
    riscos-build-run $riscos_arch "$binary" "$fixtures/two-pass,fff" \
        --command "run Assemble -cpu 6502 -input two-pass -output output" \
        --return-file output --return-to "$work/two-pass-$arch" >/dev/null
    check_hex "$work/two-pass-$arch" a9040102d0fa
    if riscos-build-run $riscos_arch "$binary" "$fixtures/undefined,fff" \
        --command "run Assemble -cpu 6502 -input undefined -output output" >/dev/null 2>&1; then
        fail "undefined symbol succeeded on $arch-bit build"
    fi
    if riscos-build-run $riscos_arch "$binary" "$fixtures/late-org,fff" \
        --command "run Assemble -cpu 6502 -input late-org -output output" >/dev/null 2>&1; then
        fail "late ORG succeeded on $arch-bit build"
    fi
    riscos-build-run $riscos_arch "$binary" "$fixtures/listing,fff" \
        --command "run Assemble -cpu 6502 -input listing -output output" >"$work/listing-$arch"
    grep -q '00000000 EA' "$work/listing-$arch" || fail "listing missing on $arch-bit build"
}

riscos-amu
arches=32
if [ "${ASSEMBLE_TEST_64:-0}" = 1 ]; then
    riscos-amu BUILD64=1
    arches="32 64"
fi

for arch in $arches; do
    run_selector_checks "$arch"
    run_two_pass_checks "$arch"
done

echo "Assemble command tests passed"
