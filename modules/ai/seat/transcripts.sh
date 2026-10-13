# The generated wrapper supplies $home, $archive and $group.
mountpoint -q /srv/storage
umask 027
install -d -m 0750 -g "$group" "$archive" "$archive"/{claude,codex,muse,opencode}

# Never --delete: keeping what the harnesses prune is the point.
copy() {
  [[ -d $1 ]] || return 0
  rsync -rt --chown="root:$group" --chmod=D750,F640 "$1/" "$2/"
}
copy "$home/.claude/projects" "$archive/claude"
copy "$home/.codex/sessions" "$archive/codex"
copy "$home/.codex/archived_sessions" "$archive/codex"
# Muse keeps each session in a directory of runtime state; only the chat
# log itself is copied, never a subagent's.
[[ -d $home/.local/share/muse/sessions ]] &&
  rsync -rt --chown="root:$group" --chmod=D750,F640 --prune-empty-dirs \
    --exclude='.*' --exclude='subagent/' --include='*/' \
    --include='session.jsonl' --exclude='*' \
    "$home/.local/share/muse/sessions/" "$archive/muse/"

# OpenCode deletes a session's rows outright, so each session is exported
# to its own file, rewritten whenever any of its rows changes.
db=$home/.local/share/opencode/opencode-stable.db
[[ -f $db ]] || exit 0
stamp=$archive/opencode/.exported
since=$(cat "$stamp" 2>/dev/null || echo 0)
# As the seat: SQLite run by root could leave root-owned WAL files behind.
query() {
  setpriv --reuid="$group" --regid="$group" --clear-groups \
    sqlite3 -readonly -bail "$db" "$@"
}
now=$(query "SELECT max(t) FROM (SELECT max(time_updated) t FROM session
  UNION ALL SELECT max(time_updated) FROM message
  UNION ALL SELECT max(time_updated) FROM part)")
now=${now:-0}
changed=$(query "SELECT id FROM session WHERE time_updated > $since
  UNION SELECT session_id FROM message WHERE time_updated > $since
  UNION SELECT session_id FROM part WHERE time_updated > $since")
for id in $changed; do
  [[ $id =~ ^[A-Za-z0-9_]+$ ]]
  out=$archive/opencode/$id.jsonl
  query "SELECT json_object('session', json_object('id', id, 'title', title,
      'directory', directory, 'parent', parent_id, 'created', time_created))
    FROM session WHERE id = '$id'" \
    "SELECT json_object('id', m.id, 'created', m.time_created,
      'message', json(m.data), 'parts', (SELECT json_group_array(json(data))
        FROM (SELECT data FROM part WHERE message_id = m.id
          ORDER BY time_created, id)))
    FROM message m WHERE m.session_id = '$id'
    ORDER BY m.time_created, m.id" > "$out.tmp"
  # A session deleted since the listing exports empty; keep the old copy.
  if [[ -s $out.tmp ]]; then
    chgrp "$group" "$out.tmp"
    mv "$out.tmp" "$out"
  else
    rm "$out.tmp"
  fi
done
echo "$now" > "$stamp"
