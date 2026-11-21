#!/usr/bin/env bash
# Refuses any dependency published less than MIN_AGE_HOURS ago: every SwiftPM pin in both
# Package.resolved files, and every `uses:` in the workflows. A compromised release is usually
# caught and yanked within a day or two; waiting that out costs nothing for a dependency we
# chose to bump anyway. Same script as MergeRight's (afitzgerald/MergeRight#157), but reading
# the workflows with yq, because the macOS runner image has no ripgrep.
#
# "Published" is the latest of the commit's date, the annotated tag's date and the GitHub
# release's date. The first two are set by whoever pushed and can be backdated; a release date
# is set by GitHub and cannot, which is why it is checked whenever one exists. A tag that no
# longer points at the pinned commit fails outright.
#
# Actions must be pinned to a commit SHA with the version as a trailing comment
# (`uses: actions/checkout@<sha> # v7.0.1`). A tag like `@v7` moves on its own, so it would
# adopt a release the moment it is cut, with no change here for this check to see.
#
# Run by the release job before it builds (a step, not a workflow of its own, so no extra
# runner); run it yourself before a PR that bumps a pin. Needs `gh` signed in (GH_TOKEN on a
# runner), `jq` and `yq`. An urgent security fix that cannot wait goes through with
# MIN_AGE_HOURS=0, said out loud in the PR rather than hidden in this file.
set -euo pipefail
cd "$(dirname "$0")/.."

MIN_AGE_HOURS=${MIN_AGE_HOURS:-72}
# Our own libraries (DiffKit) are exempt: the wait guards against someone else's release
# being compromised, and a release we cut ourselves is often the reason for the bump.
OWN_OWNERS="afitzgerald"
failed=0

fail() { echo "::error::$*"; failed=1; }

# Prints the hours since <owner/repo>@<sha> was published, checking <tag> points at it.
age_hours() {
    local repo=$1 sha=$2 tag=$3 dates ref rel
    dates=$(gh api "repos/$repo/commits/$sha" --jq .commit.committer.date)
    if [ -n "$tag" ]; then
        ref=$(gh api "repos/$repo/git/ref/tags/$tag" --jq '[.object.type, .object.sha] | @tsv')
        if [ "${ref%%$'\t'*}" = tag ]; then
            ref=$(gh api "repos/$repo/git/tags/${ref#*$'\t'}" \
                --jq '"commit\t\(.object.sha)\n\(.tagger.date)"')
            dates+=$'\n'$(tail -1 <<<"$ref")
            ref=$(head -1 <<<"$ref")
        fi
        [ "${ref#*$'\t'}" = "$sha" ] || { echo "tag $tag is ${ref#*$'\t'}, not $sha" >&2; return 1; }
        # A tag with no release is a 404 and has no date to add. Any other failure must not
        # silently drop the one date GitHub sets and nobody can backdate.
        if rel=$(gh api "repos/$repo/releases/tags/$tag" --jq .published_at 2>&1); then
            dates+=$'\n'$rel
        elif [[ $rel != *"HTTP 404"* ]]; then
            echo "release lookup for $repo $tag failed: $rel" >&2
            return 1
        fi
    fi
    jq -Rn '[inputs | select(test("^[0-9]{4}-")) | fromdateiso8601] | (now - max) / 3600 | floor' <<<"$dates"
}

check() {
    local what=$1 repo=$2 sha=$3 tag=$4 age
    if [[ " $OWN_OWNERS " == *" ${repo%%/*} "* ]]; then
        echo "own $what: $repo ${tag:-$sha} (exempt)"
    elif ! age=$(age_hours "$repo" "$sha" "$tag"); then
        fail "$what: could not date $repo@$sha"
    elif [ "$age" -lt "$MIN_AGE_HOURS" ]; then
        fail "$what: $repo ${tag:-$sha} was published ${age}h ago; wait until it is ${MIN_AGE_HOURS}h old"
    else
        echo "ok  $what: $repo ${tag:-$sha} (${age}h)"
    fi
}

for resolved in Package.resolved Moomux.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved; do
    while IFS=$'\t' read -r location sha version; do
        repo=${location#https://github.com/}
        repo=${repo%.git}
        if [ "$repo" = "$location" ]; then
            fail "$resolved: $location is not on GitHub, so its age cannot be checked"
        else
            check "$resolved" "$repo" "$sha" "$version"
        fi
    done < <(jq -r '.pins[] | [.location, .state.revision, .state.version // ""] | @tsv' "$resolved")
done

# Both lockfiles must pin the same revisions: an Xcode resolve can move one without the other.
pins() { jq -S '[.pins[] | {identity, revision: .state.revision}] | sort_by(.identity)' "$1"; }
if ! diff <(pins Package.resolved) <(pins Moomux.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved) >&2; then
    fail "the two Package.resolved files pin different revisions"
fi

for workflow in .github/workflows/*.yml; do
    while IFS=$'\t' read -r uses tag; do
        case $uses in ./*) continue ;; esac
        action=${uses%@*} sha=${uses##*@}
        if ! [[ $sha =~ ^[0-9a-f]{40}$ ]]; then
            fail "$workflow: $uses is not pinned to a commit SHA"
            continue
        fi
        # owner/repo, dropping a subdirectory action's path (github/codeql-action/init).
        IFS=/ read -r owner name _ <<<"$action"
        if [ -z "$tag" ]; then
            fail "$workflow: $uses has no trailing version comment, so its release date cannot be checked"
            continue
        fi
        check "$workflow" "$owner/$name" "$sha" "$tag"
    done < <(yq -o tsv '.. | select(tag == "!!map" and has("uses")) | [.uses, (.uses | line_comment)]' "$workflow")
done

exit "$failed"
