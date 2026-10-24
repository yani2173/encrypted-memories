# The recorder's data tree lives below one folder that only this tool uses. Two helpers guard it.
data_tree_folder_name=EncryptedMemoriesUpgradeFixtures

# A data folder is absolute, has no empty, "." or ".." component, and its last component is
# the folder name of this tool, so a mistaken value can never point at the file system root or at a shared folder.
data_base_is_valid() {
  local base="${1:-}"
  [[ "$base" == /* && "$base" != *//* && "$base/" != */./* && "$base/" != */../* \
    && "${base##*/}" == "$data_tree_folder_name" ]]
}

# Remove the data tree that one recording run created in the data folder, and nothing else.
# The caller passes the folder, the release and the run it created itself; an inherited variable is never read here.
remove_data_tree() {
  local base="${1:-}" release="${2:-}" run="${3:-}"
  [[ -n "$run" ]] || return 0
  if ! data_base_is_valid "$base"; then
    echo 'Refusing to remove a data tree below an unsafe data folder.' >&2
    return 0
  fi
  if [[ ! "$release" =~ ^v[0-9]+[.][0-9]+[.][0-9]+$ || ! "$run" =~ ^run[.][A-Za-z0-9]+$ ]]; then
    echo 'Refusing to remove a data tree with an unexpected release or run name.' >&2
    return 0
  fi
  # A failed removal must not stop the cleanup that follows.
  rm -rf -- "$base/$release/$run" || echo 'The data tree of this run could not be removed completely.' >&2
  rmdir "$base/$release" "$base" 2>/dev/null || true
  return 0
}
