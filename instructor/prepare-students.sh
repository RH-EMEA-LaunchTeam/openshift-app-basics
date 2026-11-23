#!/usr/bin/env bash
# Create student namespaces, quotas, LimitRanges, and RoleBindings.
# Applies instructor/00-student-namespace.yaml once per student id.
#
# Defaults: student-01 .. student-20 on context "cluster".
#
# Examples:
#   ./instructor/prepare-students.sh
#   ./instructor/prepare-students.sh --count 20
#   ./instructor/prepare-students.sh --count 12 --prefix student --start 1
#   ./instructor/prepare-students.sh --students student-01,student-02,lab-user-a
#   ./instructor/prepare-students.sh --dry-run
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
MANIFEST="${ROOT}/00-student-namespace.yaml"
CONTEXT="${OC_CONTEXT:-cluster}"
PREFIX="student"
START=1
COUNT=20
PAD=2
DRY_RUN=0
STUDENTS_CSV=""

usage() {
  cat <<'EOF'
Usage: prepare-students.sh [options]

Create one namespace per student from instructor/00-student-namespace.yaml.
The namespace name and RoleBinding user are the same student id.

Options:
  --count N          Number of students (default: 20)
  --start N          First number when using --prefix (default: 1)
  --prefix NAME      Id prefix (default: student) -> student-01, student-02, ...
  --pad N            Zero-pad width for numbers (default: 2)
  --students LIST    Comma-separated ids (overrides --count/--prefix/--start)
  --context NAME     oc context (default: cluster, or OC_CONTEXT)
  --dry-run          Print student ids and rendered YAML; do not apply
  -h, --help         Show this help

Requires: oc, envsubst, and cluster-admin on the target context.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --count)
      COUNT="${2:?--count requires a value}"
      shift 2
      ;;
    --start)
      START="${2:?--start requires a value}"
      shift 2
      ;;
    --prefix)
      PREFIX="${2:?--prefix requires a value}"
      shift 2
      ;;
    --pad)
      PAD="${2:?--pad requires a value}"
      shift 2
      ;;
    --students)
      STUDENTS_CSV="${2:?--students requires a value}"
      shift 2
      ;;
    --context)
      CONTEXT="${2:?--context requires a value}"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ ! -f "${MANIFEST}" ]]; then
  echo "Missing manifest: ${MANIFEST}" >&2
  exit 1
fi

for cmd in oc envsubst; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "Required command not found: ${cmd}" >&2
    exit 1
  fi
done

students=()
if [[ -n "${STUDENTS_CSV}" ]]; then
  IFS=',' read -r -a students <<< "${STUDENTS_CSV}"
else
  if ! [[ "${COUNT}" =~ ^[0-9]+$ && "${COUNT}" -ge 1 ]]; then
    echo "--count must be a positive integer" >&2
    exit 1
  fi
  if ! [[ "${START}" =~ ^[0-9]+$ && "${START}" -ge 0 ]]; then
    echo "--start must be a non-negative integer" >&2
    exit 1
  fi
  if ! [[ "${PAD}" =~ ^[0-9]+$ && "${PAD}" -ge 1 ]]; then
    echo "--pad must be a positive integer" >&2
    exit 1
  fi
  end=$((START + COUNT - 1))
  for ((i = START; i <= end; i++)); do
    students+=("$(printf "%s-%0${PAD}d" "${PREFIX}" "${i}")")
  done
fi

# Trim whitespace around ids from --students
cleaned=()
for id in "${students[@]}"; do
  id="$(echo "${id}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  [[ -z "${id}" ]] && continue
  cleaned+=("${id}")
done
students=("${cleaned[@]}")

if [[ "${#students[@]}" -eq 0 ]]; then
  echo "No student ids to create." >&2
  exit 1
fi

if [[ "${DRY_RUN}" -eq 0 ]]; then
  if ! oc --context "${CONTEXT}" whoami >/dev/null 2>&1; then
    echo "Cannot talk to context '${CONTEXT}'. Log in first, or pass --context." >&2
    exit 1
  fi
fi

echo "Students: ${#students[@]}"
echo "Context:  ${CONTEXT}"
echo "Manifest: ${MANIFEST}"
if [[ "${DRY_RUN}" -eq 1 ]]; then
  echo "Mode:     dry-run"
fi
echo

failed=0
for student in "${students[@]}"; do
  export WORKSHOP_USER="${student}"
  export WORKSHOP_NAMESPACE="${student}"
  echo "==> ${student}"
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    envsubst < "${MANIFEST}"
    echo
    continue
  fi
  if envsubst < "${MANIFEST}" | oc apply --context "${CONTEXT}" -f -; then
    :
  else
    echo "Failed to apply namespace for ${student}" >&2
    failed=1
  fi
done

if [[ "${DRY_RUN}" -eq 1 ]]; then
  echo "Dry-run complete. No objects were applied."
  exit 0
fi

if [[ "${failed}" -ne 0 ]]; then
  echo "Finished with errors." >&2
  exit 1
fi

echo
echo "Created or updated ${#students[@]} student namespaces."
echo "Verify with:"
echo "  oc get ns -l app.kubernetes.io/part-of=openshift-app-basics --context ${CONTEXT}"
