#!/usr/bin/env bash
# Batch-compile every example program under examples/ to catch build breakage.
#
# Compiles each examples/**/*.lpr with fpc against ../neural (same flags as
# tests/RunAll.sh). Console examples only: programs whose uses-clause pulls in
# the LCL widgetset (Interfaces/Forms/Graphics/...) need lazbuild + a GUI
# toolchain and are auto-skipped (listed at the end). Does NOT run the
# binaries — compile check only.
#
# Exit code is non-zero if any non-skipped example fails to compile.
#
# Examples compile in parallel, one fpc per CPU, each with its own unit and
# output directories. JOBS overrides the count; JOBS=1 is the old serial run.
#
# Usage:
#   bash scripts/BuildExamples.sh
#   LAZUTILS_PATH=/path/to/lazutils/lib/<arch> bash scripts/BuildExamples.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
NEURAL_DIR="$ROOT_DIR/neural"
EXAMPLES_DIR="$ROOT_DIR/examples"

# LazUtils is optional for the examples (none use UTF8Process), but pass it
# through when available so the flags mirror tests/RunAll.sh. Honour an
# explicit LAZUTILS_PATH if set; otherwise auto-discover it the same way the
# CI workflow and tests/RunAll.sh do, by finding the compiled utf8process.ppu.
if [ -z "${LAZUTILS_PATH:-}" ]; then
  LAZUTILS_PATH=$(find /usr/lib/lazarus /usr/share/lazarus -name "utf8process.ppu" -printf "%h\n" 2>/dev/null | head -1 || true)
fi
LAZ_FLAG=()
if [ -d "$LAZUTILS_PATH" ]; then
  LAZ_FLAG=(-Fu"$LAZUTILS_PATH")
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# A program needs the LCL widgetset (cannot compile headless with plain fpc)
# when its uses-clause references a GUI unit.
needs_gui() {
  awk 'BEGIN{IGNORECASE=1} /uses/{u=1} u{print} /;/{if(u)exit}' "$1" \
    | grep -qiE '(^|[ ,(])(Interfaces|Forms|LCLType|LCLIntf|Graphics|Controls|ComCtrls|StdCtrls|ExtCtrls)([ ,;])'
}

# Pre-existing examples that need a special build setup beyond plain fpc + neural.
# Skipped so this script gates on the regular console examples. Each also fails
# to compile on master with the same flags — they are not regressions.
declare -A SPECIAL_SKIP=(
  [examples/SimpleImageClassifierGPU/SimpleImageClassifierGPU.lpr]="needs OpenCL build (-dOpenCL + easycl)"
  [examples/Cifar10Resize/Cifar10Resize.lpr]="depends on usuperresolutionexample from examples/SuperResolution"
  [examples/StringManipulation/StringManipulation.lpr]="calls GenerateStringFromChars, absent on master too"
)

declare -a OK_LIST=() FAIL_LIST=() SKIP_LIST=()

mapfile -t LPRS < <(find "$EXAMPLES_DIR" -name '*.lpr' | sort)
echo "==> Found ${#LPRS[@]} example programs under examples/"
[ -d "$LAZUTILS_PATH" ] && echo "==> Using LazUtils: $LAZUTILS_PATH" || echo "==> LazUtils not found (optional) — building without it"
echo

JOBS="${JOBS:-$(nproc)}"

# Compile one example; the loop below reads the result from $dir.
build_one() {
  local lpr="$1" dir="$2"
  mkdir -p "$dir/units"   # fpc -FU does not create its output dir
  if fpc -B -Mobjfpc -Sh -O2 -Fu"$NEURAL_DIR" "${LAZ_FLAG[@]}" \
        -FU"$dir/units" -o"$dir/$(basename "${lpr%.lpr}")" "$lpr" >"$dir/build.log" 2>&1; then
    touch "$dir/ok"
  fi
  rm -rf "$dir/units"
}

running=0
for i in "${!LPRS[@]}"; do
  lpr="${LPRS[$i]}"
  rel="${lpr#"$ROOT_DIR"/}"
  if needs_gui "$lpr" || [ -n "${SPECIAL_SKIP[$rel]:-}" ]; then
    continue
  fi
  build_one "$lpr" "$WORK_DIR/$i" &
  running=$((running + 1))
  if [ "$running" -ge "$JOBS" ]; then
    wait -n
    running=$((running - 1))
  fi
done
wait

# Report in the same sorted order as a serial run.
for i in "${!LPRS[@]}"; do
  lpr="${LPRS[$i]}"
  rel="${lpr#"$ROOT_DIR"/}"
  if needs_gui "$lpr"; then
    SKIP_LIST+=("$rel")
    printf 'SKIP (GUI) %s\n' "$rel"
    continue
  fi
  if [ -n "${SPECIAL_SKIP[$rel]:-}" ]; then
    SKIP_LIST+=("$rel")
    printf 'SKIP (env) %s  — %s\n' "$rel" "${SPECIAL_SKIP[$rel]}"
    continue
  fi
  if [ -e "$WORK_DIR/$i/ok" ]; then
    OK_LIST+=("$rel")
    printf 'OK         %s\n' "$rel"
  else
    FAIL_LIST+=("$rel")
    printf 'FAIL       %s\n' "$rel"
    sed 's/^/    | /' "$WORK_DIR/$i/build.log" | grep -iE 'error|fatal' | head -5
  fi
done

echo
echo "==================== SUMMARY ===================="
echo "  Compiled OK : ${#OK_LIST[@]}"
echo "  Skipped     : ${#SKIP_LIST[@]}  (GUI widgetset / special build setup)"
echo "  Failed      : ${#FAIL_LIST[@]}"
if [ "${#FAIL_LIST[@]}" -gt 0 ]; then
  echo
  echo "  Failures:"
  printf '    - %s\n' "${FAIL_LIST[@]}"
  exit 1
fi
echo "  All non-GUI examples compiled cleanly."
