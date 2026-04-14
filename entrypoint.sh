#!/bin/bash

set -eo pipefail

# config
default_semvar_bump=${DEFAULT_BUMP:-minor}
default_branch=${DEFAULT_BRANCH:-$GITHUB_BASE_REF} # get the default branch from github runner env vars
with_v=${WITH_V:-false}
release_branches=${RELEASE_BRANCHES:-master,main}
custom_tag=${CUSTOM_TAG:-}
source=${SOURCE:-.}
dryrun=${DRY_RUN:-false}
git_api_tagging=${GIT_API_TAGGING:-true}
initial_version=${INITIAL_VERSION:-0.0.0}
tag_context=${TAG_CONTEXT:-repo}
tag_prefix=${TAG_PREFIX:-false}
prerelease=${PRERELEASE:-false}
suffix=${PRERELEASE_SUFFIX:-beta}
verbose=${VERBOSE:-false}
major_string_token=${MAJOR_STRING_TOKEN:-#major}
minor_string_token=${MINOR_STRING_TOKEN:-#minor}
patch_string_token=${PATCH_STRING_TOKEN:-#patch}
none_string_token=${NONE_STRING_TOKEN:-#none}
branch_history=${BRANCH_HISTORY:-compare}
force_without_changes=${FORCE_WITHOUT_CHANGES:-false}
force_without_changes_pre=${FORCE_WITHOUT_CHANGES_PRE:-false}
tag_message=${TAG_MESSAGE:-""}

# since https://github.blog/2022-04-12-git-security-vulnerability-announced/ runner uses?
git config --global --add safe.directory /github/workspace

cd "${GITHUB_WORKSPACE}/${source}" || exit 1

echo "*** CONFIGURATION ***"
echo -e "\tDEFAULT_BUMP: ${default_semvar_bump}"
echo -e "\tDEFAULT_BRANCH: ${default_branch}"
echo -e "\tWITH_V: ${with_v}"
echo -e "\tRELEASE_BRANCHES: ${release_branches}"
echo -e "\tCUSTOM_TAG: ${custom_tag}"
echo -e "\tSOURCE: ${source}"
echo -e "\tDRY_RUN: ${dryrun}"
echo -e "\tGIT_API_TAGGING: ${git_api_tagging}"
echo -e "\tINITIAL_VERSION: ${initial_version}"
echo -e "\tTAG_CONTEXT: ${tag_context}"
echo -e "\tTAG_PREFIX: ${tag_prefix}"
echo -e "\tPRERELEASE: ${prerelease}"
echo -e "\tPRERELEASE_SUFFIX: ${suffix}"
echo -e "\tVERBOSE: ${verbose}"
echo -e "\tMAJOR_STRING_TOKEN: ${major_string_token}"
echo -e "\tMINOR_STRING_TOKEN: ${minor_string_token}"
echo -e "\tPATCH_STRING_TOKEN: ${patch_string_token}"
echo -e "\tNONE_STRING_TOKEN: ${none_string_token}"
echo -e "\tBRANCH_HISTORY: ${branch_history}"
echo -e "\tFORCE_WITHOUT_CHANGES: ${force_without_changes}"
echo -e "\tFORCE_WITHOUT_CHANGES_PRE: ${force_without_changes_pre}"
echo -e "\tTAG_MESSAGE: ${tag_message}"

# verbose, show everything
if $verbose
then
    set -x
fi

setOutput() {
    echo "${1}=${2}" >> "${GITHUB_OUTPUT}"
}

current_branch=$(git rev-parse --abbrev-ref HEAD)

pre_release="$prerelease"
IFS=',' read -ra branch <<< "$release_branches"
for b in "${branch[@]}"; do
    # check if ${current_branch} is in ${release_branches} | exact branch match
    if [[ "$current_branch" == "$b" ]] && [[ "$prerelease" != "true" ]]
    then
        pre_release="false"
    fi
    # verify non specific branch names like  .* release/* if wildcard filter then =~
    if [ "$b" != "${b//[\[\]|.? +*]/}" ] && [[ "$current_branch" =~ $b ]] && [[ "$prerelease" != "true" ]]
    then
        pre_release="false"
    fi
done
echo "pre_release = $pre_release"

# fetch tags
git fetch --tags

# escape a string for use in grep -E patterns
escape_ere() {
    # escape: ] [ \ - ^ $ . | ? * + ( ) { }
    printf '%s' "$1" | sed -e 's/[][\\.^$|?*+(){}-]/\\&/g'
}

# returns 0 if the provided rev resolves to a commit, else 1
rev_exists() {
    git rev-parse -q --verify "${1}^{commit}" >/dev/null 2>&1
}

# bump a semver (no prefix) without requiring external tooling
bump_semver_fallback() {
    local part="$1"
    local ver="$2"
    if [[ ! "$ver" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
        echo "::error::Invalid semver '${ver}'"
        exit 1
    fi
    local maj="${BASH_REMATCH[1]}"
    local min="${BASH_REMATCH[2]}"
    local pat="${BASH_REMATCH[3]}"
    case "$part" in
        major) echo "$((maj+1)).0.0" ;;
        minor) echo "${maj}.$((min+1)).0" ;;
        patch) echo "${maj}.${min}.$((pat+1))" ;;
        *) echo "::error::Unknown bump part '${part}'"; exit 1 ;;
    esac
}

semver_bump() {
    local part="$1"
    local ver="$2"
    if command -v semver >/dev/null 2>&1; then
        semver -i "$part" "$ver"
    else
        bump_semver_fallback "$part" "$ver"
    fi
}

next_prerelease_tag() {
    # args: <prefix> <full-pre-tag> <suffix>
    local prefix="$1"
    local full_pre_tag="$2"
    local preid="$3"

    local ver="${full_pre_tag#"$prefix"}"
    if [[ "$ver" =~ ^([0-9]+\.[0-9]+\.[0-9]+)-${preid}\.([0-9]+)$ ]]; then
        local base="${BASH_REMATCH[1]}"
        local num="${BASH_REMATCH[2]}"
        echo "${prefix}${base}-${preid}.$((num+1))"
        return 0
    fi

    echo "::error::Unable to parse prerelease tag '${full_pre_tag}'"
    exit 1
}

# Returns 0 (true) if ver1 > ver2, 1 (false) otherwise.
# Both arguments must be bare semver: X.Y.Z (no prefix).
semver_gt() {
    local IFS='.'
    local -a a=($1) b=($2)
    for i in 0 1 2; do
        if (( ${a[i]:-0} > ${b[i]:-0} )); then return 0; fi
        if (( ${a[i]:-0} < ${b[i]:-0} )); then return 1; fi
    done
    return 1  # equal → not greater
}

# Set no tag prefix (not even v)
tagPrefix=""

if $with_v
then
    tagPrefix="v"
fi

# If a tag_prefix is supplied use that
if [[ "${tag_prefix}" != "false" ]]
then
  tagPrefix=$tag_prefix
fi

tagPrefixRe="$(escape_ere "$tagPrefix")"

# For custom TAG_PREFIX, only match tags that start with that prefix.
# For WITH_V=true (where tagPrefix="v"), allow matching both "v1.2.3" and "1.2.3".
prefixGroup="$tagPrefixRe"
if [[ "${tag_prefix}" == "false" ]] && [[ "$tagPrefix" == "v" ]]
then
    prefixGroup="(${tagPrefixRe})?"
fi

tagFmt="^${prefixGroup}[0-9]+\.[0-9]+\.[0-9]+$"
preTagFmt="^${prefixGroup}[0-9]+\.[0-9]+\.[0-9]+-${suffix}\.[0-9]+$"

# get the git refs
git_refs=
case "$tag_context" in
    *repo*)
        git_refs=$(git tag --list --sort=-v:refname)
        ;;
    *branch*)
        git_refs=$(git tag --list --merged HEAD --sort=-v:refname)
        ;;
    * ) echo "Unrecognised context"
        exit 1;;
esac

# get the latest tag that looks like a semver (with or without v)
matching_tag_refs=$( (grep -E "$tagFmt" <<< "$git_refs") || true)
matching_pre_tag_refs=$( (grep -E "$preTagFmt" <<< "$git_refs") || true)
tag=$(head -n 1 <<< "$matching_tag_refs")
pre_tag=$(head -n 1 <<< "$matching_pre_tag_refs")

# if there are none, start tags at initial version
if [ -z "$tag" ]
then
    tag="$tagPrefix$initial_version"
    if [ -z "$pre_tag" ] && $pre_release
    then
        pre_tag="$tagPrefix$initial_version"
    fi
fi

# get current commit hash for tag (only if it exists)
tag_commit=""
if rev_exists "$tag"
then
    tag_commit=$(git rev-list -n 1 "$tag")
fi
# get current commit hash
commit=$(git rev-parse HEAD)
# skip if there are no new commits for non-pre_release
if [ "$tag_commit" == "$commit" ] && [ "$force_without_changes" == "false" ]
then
    echo "No new commits since previous tag. Skipping..."
    setOutput "new_tag" "$tag"
    setOutput "tag" "$tag"
    exit 0
fi

# sanitize that the default_branch is set (via env var when running on PRs) else find it natively
if [ -z "${default_branch}" ] && [ "$branch_history" == "full" ]
then
    echo "The DEFAULT_BRANCH should be autodetected when tag-action runs on on PRs else must be defined, See: https://github.com/anothrNick/github-tag-action/pull/230, since is not defined we find it natively"
    default_branch=$(git branch -rl '*/master' '*/main' | cut -d / -f2)
    echo "default_branch=${default_branch}"
    # re check this
    if [ -z "${default_branch}" ]
    then
        echo "::error::DEFAULT_BRANCH must not be null, something has gone wrong."
        exit 1
    fi
fi

# get the merge commit message looking for #bumps
compare_base_commit="$tag_commit"
if $pre_release
then
    if rev_exists "$pre_tag"
    then
        compare_base_commit=$(git rev-list -n 1 "$pre_tag")
    else
        compare_base_commit=""
    fi
fi
declare -A history_type=(
    ["last"]="$(git show -s --format=%B)" \
    ["full"]="$(git log "${default_branch}"..HEAD --format=%B)" \
    ["compare"]="$(if [ -n "$compare_base_commit" ]; then git log "${compare_base_commit}".."${commit}" --format=%B; else git log "${commit}" --format=%B; fi)" \
)
log=${history_type[${branch_history}]}
printf "History:\n---\n%s\n---\n" "$log"

if [ -z "$tagPrefix" ]
then
  current_tag=${tag}
else
  current_tag="${tag#"$tagPrefix"}"
fi

# Decide whether to continue an existing prerelease stream (bump rc.N → rc.N+1)
# or start a fresh one from the next bumped version.
# We only continue when the prerelease base version is strictly ahead of the
# latest release tag — otherwise a newer release has landed and the old
# prerelease stream is stale.
continuing_prerelease=false
if $pre_release && rev_exists "$pre_tag"
then
    # Extract the base semver from the prerelease tag (e.g. "v0.1.0-rc.2" → "0.1.0")
    pre_tag_base="${pre_tag#"$tagPrefix"}"
    pre_tag_base="${pre_tag_base%%-*}"

    if semver_gt "$pre_tag_base" "$current_tag"
    then
        continuing_prerelease=true
    fi
fi

case "$log" in
    *$major_string_token* ) new=${tagPrefix}$(semver_bump major "${current_tag}"); part="major";;
    *$minor_string_token* ) new=${tagPrefix}$(semver_bump minor "${current_tag}"); part="minor";;
    *$patch_string_token* ) new=${tagPrefix}$(semver_bump patch "${current_tag}"); part="patch";;
    *$none_string_token* )
        echo "Default bump was set to none. Skipping..."
        setOutput "old_tag" "$tag"
        setOutput "new_tag" "$tag"
        setOutput "tag" "$tag"
        setOutput "part" "$default_semvar_bump"
        exit 0;;
    * )
        if [ "$default_semvar_bump" == "none" ]
        then
            echo "Default bump was set to none. Skipping..."
            setOutput "old_tag" "$tag"
            setOutput "new_tag" "$tag"
            setOutput "tag" "$tag"
            setOutput "part" "$default_semvar_bump"
            exit 0
        else
            new=${tagPrefix}$(semver_bump "${default_semvar_bump}" "${current_tag}")
            part=$default_semvar_bump
        fi
        ;;
esac

if $pre_release
then
    # get current commit hash for tag
    pre_tag_commit=""
    if rev_exists "$pre_tag"
    then
        pre_tag_commit=$(git rev-list -n 1 "$pre_tag")
    fi
    # skip if there are no new commits for pre_release
    if [ "$pre_tag_commit" == "$commit" ] &&  [ "$force_without_changes_pre" == "false" ]
    then
        echo "No new commits since previous pre_tag. Skipping..."
        setOutput "new_tag" "$pre_tag"
        setOutput "tag" "$pre_tag"
        exit 0
    fi
    # If we're continuing an existing prerelease stream, just bump rc.N -> rc.(N+1)
    if $continuing_prerelease
    then
        new=$(next_prerelease_tag "$tagPrefix" "$pre_tag" "$suffix")
        echo -e "Bumping ${suffix} pre-tag ${pre_tag}. New pre-tag ${new}"
    else
        new="${new}-${suffix}.0"
        echo -e "Setting ${suffix} pre-tag ${pre_tag} - With pre-tag ${new}"
    fi
    part="pre-$part"
else
    echo -e "Bumping tag ${tag} - New tag ${new}"
fi

# as defined in readme if CUSTOM_TAG is used any semver calculations are irrelevant.
if [ -n "$custom_tag" ]
then
    new="$custom_tag"
fi

# set outputs
setOutput "new_tag" "$new"
setOutput "part" "$part"
setOutput "tag" "$new" # this needs to go in v2 is breaking change
if $pre_release
then
    setOutput "old_tag" "$pre_tag"
else
    setOutput "old_tag" "$tag"
fi

# dry run exit without real changes
if $dryrun
then
    exit 0
fi

# Modify the tag creation part
if [ -n "$tag_message" ]
then
    echo "EVENT: creating local tag $new with message: $tag_message"
    git tag -a "$new" -m "$tag_message" || exit 1
else
    echo "EVENT: creating local tag $new"
    git tag -f "$new" || exit 1
fi

echo "EVENT: pushing tag $new to origin"

if $git_api_tagging
then
    # use git api to push
    dt=$(date '+%Y-%m-%dT%H:%M:%SZ')
    full_name=$GITHUB_REPOSITORY
    git_refs_url=$(jq .repository.git_refs_url "$GITHUB_EVENT_PATH" | tr -d '"' | sed 's/{\/sha}//g')

    echo "$dt: **pushing tag $new to repo $full_name"

    git_refs_response=$(
    curl -s -X POST "$git_refs_url" \
    -H "Authorization: token $GITHUB_TOKEN" \
    -d @- << EOF
{
    "ref": "refs/tags/$new",
    "sha": "$commit"
}
EOF
)

    git_ref_posted=$( echo "${git_refs_response}" | jq .ref | tr -d '"' )

    echo "::debug::${git_refs_response}"
    if [ "${git_ref_posted}" = "refs/tags/${new}" ]
    then
        exit 0
    else
        echo "::error::Tag was not created properly."
        exit 1
    fi
else
    # use git cli to push
    git push -f origin "$new" || exit 1
fi
