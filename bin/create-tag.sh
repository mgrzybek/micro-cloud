#!/usr/bin/env bash
#
# Create and push a signed release tag, which triggers
# .github/workflows/release.yml (OCI artifact + latest + GitHub Release).
#
# Run it yourself, from an up-to-date main:
#   bash create-tag.sh v0.1.0-rc.1   # throwaway pre-release to validate the workflow
#   bash create-tag.sh v0.1.0        # final release

set -euo pipefail

cd "$(dirname "$0")"

version="${1:-}"

if [[ -z "$version" ]]; then
	echo "usage: $0 <version>   e.g. v0.1.0 or v0.1.0-rc.1" >&2
	exit 1
fi

if [[ ! "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-rc\.[0-9]+)?$ ]]; then
	echo "error: version must look like v1.2.3 or v1.2.3-rc.1 (got: $version)" >&2
	exit 1
fi

# Release tags are cut from an up-to-date main.
branch="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$branch" != "main" ]]; then
	echo "error: not on main (on '$branch') — release tags are cut from main." >&2
	exit 1
fi

if ! git diff --quiet || ! git diff --cached --quiet; then
	echo "error: working tree is not clean — commit or stash first." >&2
	exit 1
fi

git fetch --quiet origin main
if [[ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]]; then
	echo "error: local main is not in sync with origin/main — pull first." >&2
	exit 1
fi

if git rev-parse -q --verify "refs/tags/$version" >/dev/null ||
	git ls-remote --exit-code --tags origin "$version" >/dev/null 2>&1; then
	echo "error: tag $version already exists (locally or on origin)." >&2
	exit 1
fi

# For a final release, sanity-check that the changelog mentions it.
if [[ ! "$version" =~ -rc\. ]] && ! grep -qF "[${version#v}]" CHANGELOG.md; then
	echo "warning: CHANGELOG.md has no '[${version#v}]' section — continuing anyway." >&2
fi

echo "Tagging $(git log -1 --oneline) as $version"
git tag -s "$version" -m "release: $version"
git push origin "$version"

echo
echo "Pushed $version — the release workflow is running."
echo "Watch it with: gh run list --workflow=release.yml"
echo "Release page:  gh release view $version"

if [[ "$version" =~ -rc\. ]]; then
	echo
	echo "This is a throwaway pre-release. Once validated, remove it with:"
	echo "  git push origin :refs/tags/$version && git tag -d $version"
	echo "  gh release delete $version --yes   # if a Release was created"
fi
