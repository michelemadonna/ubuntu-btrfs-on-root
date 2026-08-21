#!/usr/bin/env bash
set -euo pipefail

repo_root="$(
	cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." &&
		pwd
)"

cd "$repo_root"

printf '==> Bash syntax\n'

while IFS= read -r -d '' file; do
	bash -n "$file"
done < <(
	find . \
		-type f \
		-name '*.sh' \
		-print0
)

printf '==> ShellCheck\n'

find . \
	-type f \
	-name '*.sh' \
	-print0 |
	xargs -0 shellcheck

printf '==> Formatting\n'

shfmt -d .

printf '==> Validation complete\n'
