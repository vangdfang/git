#!/bin/sh
#
# Copyright (c) 2006 Johannes E. Schindelin

# SHORT DESCRIPTION
#
# This script makes it easy to fix up commits in the middle of a series,
# and rearrange commits.
#
# The original idea comes from Eric W. Biederman, in
# http://article.gmane.org/gmane.comp.version-control.git/22407
#
# The file containing rebase commands, comments, and empty lines.
# This file is created by "git rebase -i" then edited by the user.  As
# the lines are processed, they are removed from the front of this
# file and written to the tail of $done.
todo="$state_dir"/git-rebase-todo

# The rebase command lines that have already been processed.  A line
# is moved here when it is first handled, before any associated user
# actions.
done="$state_dir"/done

# The commit message that is planned to be used for any changes that
# need to be committed following a user interaction.
msg="$state_dir"/message

# The file into which is accumulated the suggested commit message for
# squash/fixup commands.  When the first of a series of squash/fixups
# is seen, the file is created and the commit message from the
# previous commit and from the first squash/fixup commit are written
# to it.  The commit message for each subsequent squash/fixup commit
# is appended to the file as it is processed.
#
# The first line of the file is of the form
#     # This is a combination of $count commits.
# where $count is the number of commits whose messages have been
# written to the file so far (including the initial "pick" commit).
# Each time that a commit message is processed, this line is read and
# updated.  It is deleted just before the combined commit is made.
squash_msg="$state_dir"/message-squash

# If the current series of squash/fixups has not yet included a squash
# command, then this file exists and holds the commit message of the
# original "pick" commit.  (If the series ends without a "squash"
# command, then this can be used as the commit message of the combined
# commit without opening the editor.)
fixup_msg="$state_dir"/message-fixup

dropped="$state_dir"/dropped

# A script to set the GIT_AUTHOR_NAME, GIT_AUTHOR_EMAIL, and
# GIT_AUTHOR_DATE that will be used for the commit that is currently
# being rebased.
author_script="$state_dir"/author-script

# When an "edit" rebase command is being processed, the SHA1 of the
# commit to be edited is recorded in this file.  When "git rebase
# --continue" is executed, if there are any staged changes then they
# will be amended to the HEAD commit, but only provided the HEAD
# commit is still the commit to be edited.  When any other rebase
# command is processed, this file is deleted.
amend="$state_dir"/amend

# For the post-rewrite hook, we make a list of rewritten commits and
# their new sha1s.  The rewritten-pending list keeps the sha1s of
# commits that have been processed, but not committed yet,
# e.g. because they are waiting for a 'squash' command.
rewritten_list="$state_dir"/rewritten-list
rewritten_pending="$state_dir"/rewritten-pending

GIT_CHERRY_PICK_HELP="$resolvemsg"
export GIT_CHERRY_PICK_HELP

warn () {
	printf '%s\n' "$*" >&2
}

# Output the commit message for the specified commit.
commit_message () {
	git cat-file commit "$1" | sed "1,/^$/d"
}

orig_reflog_action="$GIT_REFLOG_ACTION"

comment_for_reflog () {
	case "$orig_reflog_action" in
	''|rebase*)
		GIT_REFLOG_ACTION="rebase -i ($1)"
		export GIT_REFLOG_ACTION
		;;
	esac
}

last_count=
mark_action_done () {
	sed -e 1q < "$todo" >> "$done"
	sed -e 1d < "$todo" >> "$todo".new
	mv -f "$todo".new "$todo"
	new_count=$(sane_grep -c '^[^#]' < "$done")
	total=$(($new_count+$(sane_grep -c '^[^#]' < "$todo")))
	if test "$last_count" != "$new_count"
	then
		last_count=$new_count
		printf "Rebasing (%d/%d)\r" $new_count $total
		test -z "$verbose" || echo
	fi
}

append_todo_help () {
	cat >> "$todo" << EOF
#
# Commands:
#  p, pick = use commit
#  r, reword = use commit, but edit the commit message
#  e, edit = use commit, but stop for amending
#  s, squash = use commit, but meld into previous commit
#  f, fixup = like "squash", but discard this commit's log message
#  x, exec = run command (the rest of the line) using shell
#  l, label = mark current commit for later use
#  g, goto = go to a previously labeled commit
#  m, merge = perform a merge
#
# These lines can be re-ordered; they are executed from top to bottom.
#
# If you remove a line here THAT COMMIT WILL BE LOST.
EOF
}

make_patch () {
	sha1_and_parents="$(git rev-list --parents -1 "$1")"
	case "$sha1_and_parents" in
	?*' '?*' '?*)
		git diff --cc $sha1_and_parents
		;;
	?*' '?*)
		git diff-tree -p "$1^!"
		;;
	*)
		echo "Root commit"
		;;
	esac > "$state_dir"/patch
	test -f "$msg" ||
		commit_message "$1" > "$msg"
	test -f "$author_script" ||
		get_author_ident_from_commit "$1" > "$author_script"
}

die_with_patch () {
	echo "$1" > "$state_dir"/stopped-sha
	make_patch "$1"
	git rerere
	die "$2"
}

exit_with_patch () {
	echo "$1" > "$state_dir"/stopped-sha
	make_patch $1
	git rev-parse --verify HEAD > "$amend"
	warn "You can amend the commit now, with"
	warn
	warn "	git commit --amend"
	warn
	warn "Once you are satisfied with your changes, run"
	warn
	warn "	git rebase --continue"
	warn
	exit $2
}

die_abort () {
	rm -rf "$state_dir"
	die "$1"
}

has_action () {
	sane_grep '^[^#]' "$1" >/dev/null
}

is_empty_commit() {
	tree=$(git rev-parse -q --verify "$1"^{tree} 2>/dev/null ||
		die "$1: not a commit that can be picked")
	ptree=$(git rev-parse -q --verify "$1"^^{tree} 2>/dev/null ||
		ptree=4b825dc642cb6eb9a060e54bf8d69288fbee4904)
	test "$tree" = "$ptree"
}

# Run command with GIT_AUTHOR_NAME, GIT_AUTHOR_EMAIL, and
# GIT_AUTHOR_DATE exported from the current environment.
do_with_author () {
	(
		export GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE
		"$@"
	)
}

git_sequence_editor () {
	if test -z "$GIT_SEQUENCE_EDITOR"
	then
		GIT_SEQUENCE_EDITOR="$(git config sequence.editor)"
		if [ -z "$GIT_SEQUENCE_EDITOR" ]
		then
			GIT_SEQUENCE_EDITOR="$(git var GIT_EDITOR)" || return $?
		fi
	fi

	eval "$GIT_SEQUENCE_EDITOR" '"$@"'
}

pick_one () {
	ff=--ff

	case "$1" in -n) sha1=$2; ff= ;; *) sha1=$1 ;; esac
	case "$force_rebase" in '') ;; ?*) ff= ;; esac
	output git rev-parse --verify $sha1 || die "Invalid commit name: $sha1"

	if is_empty_commit "$sha1"
	then
		empty_args="--allow-empty"
	fi

	output git cherry-pick $empty_args $ff "$@"
}

nth_string () {
	case "$1" in
	*1[0-9]|*[04-9]) echo "$1"th;;
	*1) echo "$1"st;;
	*2) echo "$1"nd;;
	*3) echo "$1"rd;;
	esac
}

update_squash_messages () {
	if test -f "$squash_msg"; then
		mv "$squash_msg" "$squash_msg".bak || exit
		count=$(($(sed -n \
			-e "1s/^# This is a combination of \(.*\) commits\./\1/p" \
			-e "q" < "$squash_msg".bak)+1))
		{
			echo "# This is a combination of $count commits."
			sed -e 1d -e '2,/^./{
				/^$/d
			}' <"$squash_msg".bak
		} >"$squash_msg"
	else
		commit_message HEAD > "$fixup_msg" || die "Cannot write $fixup_msg"
		count=2
		{
			echo "# This is a combination of 2 commits."
			echo "# The first commit's message is:"
			echo
			cat "$fixup_msg"
		} >"$squash_msg"
	fi
	case $1 in
	squash)
		rm -f "$fixup_msg"
		echo
		echo "# This is the $(nth_string $count) commit message:"
		echo
		commit_message $2
		;;
	fixup)
		echo
		echo "# The $(nth_string $count) commit message will be skipped:"
		echo
		commit_message $2 | sed -e 's/^/#	/'
		;;
	esac >>"$squash_msg"
}

peek_next_command () {
	sed -n -e "/^#/d" -e '/^$/d' -e "s/ .*//p" -e "q" < "$todo"
}

# A squash/fixup has failed.  Prepare the long version of the squash
# commit message, then die_with_patch.  This code path requires the
# user to edit the combined commit message for all commits that have
# been squashed/fixedup so far.  So also erase the old squash
# messages, effectively causing the combined commit to be used as the
# new basis for any further squash/fixups.  Args: sha1 rest
die_failed_squash() {
	mv "$squash_msg" "$msg" || exit
	rm -f "$fixup_msg"
	cp "$msg" "$GIT_DIR"/MERGE_MSG || exit
	warn
	warn "Could not apply $1... $2"
	die_with_patch $1 ""
}

flush_rewritten_pending() {
	test -s "$rewritten_pending" || return
	newsha1="$(git rev-parse HEAD^0)"
	sed "s/$/ $newsha1/" < "$rewritten_pending" >> "$rewritten_list"
	rm -f "$rewritten_pending"
}

record_in_rewritten() {
	oldsha1="$(git rev-parse $1)"
	echo "$oldsha1" >> "$rewritten_pending"

	case "$(peek_next_command)" in
	squash|s|fixup|f)
		;;
	*)
		flush_rewritten_pending
		;;
	esac
}

do_pick () {
	if test "$(git rev-parse HEAD)" = "$squash_onto"
	then
		# Set the correct commit message and author info on the
		# sentinel root before cherry-picking the original changes
		# without committing (-n).  Finally, update the sentinel again
		# to include these changes.  If the cherry-pick results in a
		# conflict, this means our behaviour is similar to a standard
		# failed cherry-pick during rebase, with a dirty index to
		# resolve before manually running git commit --amend then git
		# rebase --continue.
		git commit --allow-empty --allow-empty-message --amend \
			   --no-post-rewrite -n -q -C $1 &&
			pick_one -n $1 &&
			git commit --allow-empty --allow-empty-message \
				   --amend --no-post-rewrite -n -q -C $1 ||
			die_with_patch $1 "Could not apply $1... $2"
	else
		pick_one $1 ||
			die_with_patch $1 "Could not apply $1... $2"
	fi
}

do_next () {
	rm -f "$msg" "$author_script" "$amend" || exit
	read -r command sha1 rest < "$todo"
	case "$command" in
	'#'*|''|noop)
		mark_action_done
		;;
	pick|p)
		comment_for_reflog pick

		mark_action_done
		do_pick $sha1 "$rest"
		record_in_rewritten $sha1
		;;
	reword|r)
		comment_for_reflog reword

		mark_action_done
		do_pick $sha1 "$rest"
		git commit --amend --no-post-rewrite || {
			warn "Could not amend commit after successfully picking $sha1... $rest"
			warn "This is most likely due to an empty commit message, or the pre-commit hook"
			warn "failed. If the pre-commit hook failed, you may need to resolve the issue before"
			warn "you are able to reword the commit."
			exit_with_patch $sha1 1
		}
		record_in_rewritten $sha1
		;;
	edit|e)
		comment_for_reflog edit

		mark_action_done
		do_pick $sha1 "$rest"
		warn "Stopped at $sha1... $rest"
		exit_with_patch $sha1 0
		;;
	squash|s|fixup|f)
		case "$command" in
		squash|s)
			squash_style=squash
			;;
		fixup|f)
			squash_style=fixup
			;;
		esac
		comment_for_reflog $squash_style

		test -f "$done" && has_action "$done" ||
			die "Cannot '$squash_style' without a previous commit"

		mark_action_done
		update_squash_messages $squash_style $sha1
		author_script_content=$(get_author_ident_from_commit HEAD)
		echo "$author_script_content" > "$author_script"
		eval "$author_script_content"
		if ! pick_one -n $sha1
		then
			git rev-parse --verify HEAD >"$amend"
			die_failed_squash $sha1 "$rest"
		fi
		case "$(peek_next_command)" in
		squash|s|fixup|f)
			# This is an intermediate commit; its message will only be
			# used in case of trouble.  So use the long version:
			do_with_author output git commit --amend --no-verify -F "$squash_msg" ||
				die_failed_squash $sha1 "$rest"
			;;
		*)
			# This is the final command of this squash/fixup group
			if test -f "$fixup_msg"
			then
				do_with_author git commit --amend --no-verify -F "$fixup_msg" ||
					die_failed_squash $sha1 "$rest"
			else
				cp "$squash_msg" "$GIT_DIR"/SQUASH_MSG || exit
				rm -f "$GIT_DIR"/MERGE_MSG
				do_with_author git commit --amend --no-verify -F "$GIT_DIR"/SQUASH_MSG -e ||
					die_failed_squash $sha1 "$rest"
			fi
			rm -f "$squash_msg" "$fixup_msg"
			;;
		esac
		record_in_rewritten $sha1
		;;
	x|"exec")
		read -r command rest < "$todo"
		mark_action_done
		printf 'Executing: %s\n' "$rest"
		# "exec" command doesn't take a sha1 in the todo-list.
		# => can't just use $sha1 here.
		git rev-parse --verify HEAD > "$state_dir"/stopped-sha
		${SHELL:-@SHELL_PATH@} -c "$rest" # Actual execution
		status=$?
		# Run in subshell because require_clean_work_tree can die.
		dirty=f
		(require_clean_work_tree "rebase" 2>/dev/null) || dirty=t
		if test "$status" -ne 0
		then
			warn "Execution failed: $rest"
			test "$dirty" = f ||
			warn "and made changes to the index and/or the working tree"

			warn "You can fix the problem, and then run"
			warn
			warn "	git rebase --continue"
			warn
			if test $status -eq 127		# command not found
			then
				status=1
			fi
			exit "$status"
		elif test "$dirty" = t
		then
			warn "Execution succeeded: $rest"
			warn "but left changes to the index and/or the working tree"
			warn "Commit or stash your changes, and then run"
			warn
			warn "	git rebase --continue"
			warn
			exit 1
		fi
		;;
	label|l)
		mkdir -p "$state_dir"/labels
		test -f "$state_dir"/labels/"$sha1" &&
		die "Mark $sha1 already exists"
		git rev-parse HEAD > "$state_dir"/labels/"$sha1"
		mark_action_done
		;;
	goto|g)
		commit="$(cat "$state_dir"/labels/"$sha1")" ||
		die "No such mark: $sha1"
		git checkout $commit^0 ||
		die "Invalid mark: $sha1 ($commit)"
		mark_action_done
		;;
	merge|m)
		# TODO: skip if we can fast-forward
		mark_action_done
		case "$sha1" in
		-c)
			sha1=${rest%% *}
			message="$(git cat-file commit $sha1 |
				sed '1,/^$/d')" ||
			die "Invalid merge commit: $sha1"
			parents=${rest#* }
			;;
		*)
			parents="$sha1 $rest"
			message="Merge $parents"
			;;
		esac
		parents=$(for parent in $parents
			do
				case "$parent" in
				rewritten-*|onto)
					cat "$state_dir"/labels/"$parent" ||
					die "Invalid parent: $parent"
					;;
				*)
					echo "$parent"
					;;
				esac
			done) ||
		die "Could not parse parents: $parents"
		git merge --no-ff -m "$message" $parents ||
		die "Could not merge "
		;;
	*)
		warn "Unknown command: $command $sha1 $rest"
		fixtodo="Please fix this using 'git rebase --edit-todo'."
		if git rev-parse --verify -q "$sha1" >/dev/null
		then
			die_with_patch $sha1 "$fixtodo"
		else
			die "$fixtodo"
		fi
		;;
	esac
	test -s "$todo" && return

	comment_for_reflog finish &&
	newhead=$(git rev-parse HEAD) &&
	case $head_name in
	refs/*)
		message="$GIT_REFLOG_ACTION: $head_name onto $onto" &&
		git update-ref -m "$message" $head_name $newhead $orig_head &&
		git symbolic-ref \
		  -m "$GIT_REFLOG_ACTION: returning to $head_name" \
		  HEAD $head_name
		;;
	esac && {
		test ! -f "$state_dir"/verbose ||
			git diff-tree --stat $orig_head..HEAD
	} &&
	{
		test -s "$rewritten_list" &&
		git notes copy --for-rewrite=rebase < "$rewritten_list" ||
		true # we don't care if this copying failed
	} &&
	if test -x "$GIT_DIR"/hooks/post-rewrite &&
		test -s "$rewritten_list"; then
		"$GIT_DIR"/hooks/post-rewrite rebase < "$rewritten_list"
		true # we don't care if this hook failed
	fi &&
	rm -rf "$state_dir" &&
	git gc --auto &&
	warn "Successfully rebased and updated $head_name."

	exit
}

do_rest () {
	while :
	do
		do_next
	done
}

# skip picking commits whose parents are unchanged
skip_unnecessary_picks () {
	fd=3
	while read -r command rest
	do
		# fd=3 means we skip the command
		case "$fd,$command" in
		3,pick|3,p)
			# pick a commit whose parent is current $onto -> skip
			sha1=${rest%% *}
			case "$(git rev-parse --verify --quiet "$sha1"^)" in
			"$onto"*)
				onto=$sha1
				;;
			*)
				fd=1
				;;
			esac
			;;
		3,#*|3,)
			# copy comments
			;;
		*)
			fd=1
			;;
		esac
		printf '%s\n' "$command${rest:+ }$rest" >&$fd
	done <"$todo" >"$todo.new" 3>>"$done" &&
	mv -f "$todo".new "$todo" &&
	case "$(peek_next_command)" in
	squash|s|fixup|f)
		record_in_rewritten "$onto"
		;;
	esac ||
	die "Could not skip unnecessary pick commands"
}

# Rearrange the todo list that has both "pick sha1 msg" and
# "pick sha1 fixup!/squash! msg" appears in it so that the latter
# comes immediately after the former, and change "pick" to
# "fixup"/"squash".
rearrange_squash () {
	# extract fixup!/squash! lines and resolve any referenced sha1's
	while read -r pick sha1 message
	do
		case "$message" in
		"squash! "*|"fixup! "*)
			action="${message%%!*}"
			rest="${message#*! }"
			echo "$sha1 $action $rest"
			# if it's a single word, try to resolve to a full sha1 and
			# emit a second copy. This allows us to match on both message
			# and on sha1 prefix
			if test "${rest#* }" = "$rest"; then
				fullsha="$(git rev-parse -q --verify "$rest" 2>/dev/null)"
				if test -n "$fullsha"; then
					# prefix the action to uniquely identify this line as
					# intended for full sha1 match
					echo "$sha1 +$action $fullsha"
				fi
			fi
		esac
	done >"$1.sq" <"$1"
	test -s "$1.sq" || return

	used=
	while read -r pick sha1 message
	do
		case " $used" in
		*" $sha1 "*) continue ;;
		esac
		printf '%s\n' "$pick $sha1 $message"
		used="$used$sha1 "
		while read -r squash action msg_content
		do
			case " $used" in
			*" $squash "*) continue ;;
			esac
			emit=0
			case "$action" in
			+*)
				action="${action#+}"
				# full sha1 prefix test
				case "$msg_content" in "$sha1"*) emit=1;; esac ;;
			*)
				# message prefix test
				case "$message" in "$msg_content"*) emit=1;; esac ;;
			esac
			if test $emit = 1; then
				printf '%s\n' "$action $squash $action! $msg_content"
				used="$used$squash "
			fi
		done <"$1.sq"
	done >"$1.rearranged" <"$1"
	cat "$1.rearranged" >"$1"
	rm -f "$1.sq" "$1.rearranged"
}

# Add commands after a pick or after a squash/fixup serie
# in the todo list.
add_exec_commands () {
	{
		first=t
		while read -r insn rest
		do
			case $insn in
			pick)
				test -n "$first" ||
				printf "%s" "$cmd"
				;;
			esac
			printf "%s %s\n" "$insn" "$rest"
			first=
		done
		printf "%s" "$cmd"
	} <"$1" >"$1.new" &&
	mv "$1.new" "$1"
}

case "$action" in
continue)
	# do we have anything to commit?
	if git diff-index --cached --quiet HEAD --
	then
		: Nothing to commit -- skip this
	else
		if ! test -f "$author_script"
		then
			die "You have staged changes in your working tree. If these changes are meant to be
squashed into the previous commit, run:

  git commit --amend

If they are meant to go into a new commit, run:

  git commit

In both case, once you're done, continue with:

  git rebase --continue
"
		fi
		. "$author_script" ||
			die "Error trying to find the author identity to amend commit"
		if test -f "$amend"
		then
			current_head=$(git rev-parse --verify HEAD)
			test "$current_head" = $(cat "$amend") ||
			die "\
You have uncommitted changes in your working tree. Please, commit them
first and then run 'git rebase --continue' again."
			do_with_author git commit --amend --no-verify -F "$msg" -e ||
				die "Could not commit staged changes."
		else
			do_with_author git commit --no-verify -F "$msg" -e ||
				die "Could not commit staged changes."
		fi
	fi

	record_in_rewritten "$(cat "$state_dir"/stopped-sha)"

	require_clean_work_tree "rebase"
	do_rest
	;;
skip)
	git rerere clear

	do_rest
	;;
edit-todo)
	sed -e '/^#/d' < "$todo" > "$todo".new
	mv -f "$todo".new "$todo"
	append_todo_help
	cat >> "$todo" << EOF
#
# You are editing the todo file of an ongoing interactive rebase.
# To continue rebase after editing, run:
#     git rebase --continue
#
EOF

	git_sequence_editor "$todo" ||
		die "Could not execute editor"

	exit
	;;
esac

git var GIT_COMMITTER_IDENT >/dev/null ||
	die "You need to set your committer info first"

comment_for_reflog start

if test ! -z "$switch_to"
then
	output git checkout "$switch_to" -- ||
		die "Could not checkout $switch_to"
fi

orig_head=$(git rev-parse --verify HEAD) || die "No HEAD?"
mkdir "$state_dir" || die "Could not create temporary $state_dir"

: > "$state_dir"/interactive || die "Could not mark as interactive"
write_basic_state

shorthead=$(git rev-parse --short $orig_head)
shortonto=$(git rev-parse --short $onto)
if test -z "$rebase_root"
	# this is now equivalent to ! -z "$upstream"
then
	shortupstream=$(git rev-parse --short $upstream)
	revisions=$upstream...$orig_head
	shortrevisions=$shortupstream..$shorthead
	upstreamdotdot=$shortupstream..
else
	revisions=$onto...$orig_head
	shortrevisions=$shorthead
	upstreamdotdot=
fi
git rev-list --no-merges --cherry-pick --pretty=oneline --abbrev-commit \
	--abbrev=7 --reverse --left-right --topo-order \
	$revisions | \
	sed -n "s/^>//p" |
while read -r shortsha1 rest
do

	if test -z "$keep_empty" && is_empty_commit $shortsha1
	then
		comment_out="# "
	else
		comment_out=
	fi

	printf '%s\n' "${comment_out}pick $shortsha1 $rest" >>"$todo"
done

test t = "$preserve_merges" && {
	# --topo-order has the bad habit of breaking first-parent chains
	# over merges, so we do it ourselves here

	oldtodo="$(cat "$todo")"
	list="$(git log --format='%h %p' --reverse $upstreamdotdot$orig_head)"
	newtodo='label onto'

	toberebased=" $(echo "$list" | cut -f 1 -d ' ' | tr '\n' ' ')"
	handled=
	needslabel=

	# each tip is an end point of a commit->first parent chain
	branch_tips="$(printf '%s\n. . %s' "$list" "$shorthead" |
		cut -f 3- -d ' ' |
		tr ' ' '\n' |
		grep -v '^$')"
	for tip in $branch_tips
	do
		# if this is not a commit to be rebased, skip
		case "$toberebased" in *" $tip "*) ;; *) continue;; esac

		# if it is handled already, skip
		case "$handled " in *" $tip "*) continue;; esac

		# start sub-todo for this tip
		part=
		commit=$tip
		while true
		do
			# if already handled, this is our branch point
			case "$handled " in
			*" $commit "*)
				needslabel="$needslabel $commit"
				part="$(printf '%s # %s\n%s' \
					"goto rewritten-$commit" \
					"$(git show -s --format=%s $commit)" \
					"$part")"
				break
				;;
			esac

			line="$(echo "$list" | grep "^$commit ")"
			# if there is no line, branch from the 'onto' commit
			if test -z "$line"
			then
				part="$(printf '%s\n%s' \
					"goto onto" "$part")"
				break
			fi
			parents=${line#* }
			case "$parents" in
			*' '*)
				# merge
				merge_parents="$(for parent in ${parents#* }
					do
						case "$toberebased" in
						*" $parent "*)
							printf rewritten-
							;;
						esac
						echo "$parent "
					done)"
				needslabel="$needslabel $(echo "$merge_parents" |
					tr ' ' '\n' |
					sed -n 's/^rewritten-//p')"
				part="$(printf '%s\n%s\n%s' \
					"# $(git show -s --format=%s $commit)" \
					"merge -c $commit ${merge_parents% }" \
					"$part")"
				;;
			*)
				# non-merge commit
				line="$(echo "$oldtodo" | grep "^pick $commit")"
				if test -z "$line"
				then
					line="# skip $commit"
				fi
				part="$(printf '%s\n%s' "$line" "$part")"
				;;
			esac
			handled="$handled $commit"
			commit=${parents%% *}
		done
		newtodo="$(printf '%s\n\n%s' "$newtodo" "$part")"
	done

	for commit in $needslabel
	do
		newtodo="$(echo "$newtodo" |
			sed "s/^\(pick\|# skip\|merge -c\) $commit.*/&\\nlabel rewritten-$commit/")"
	done
	newtodo="$(echo "$newtodo" | uniq)"
	echo "$newtodo" > "$todo"
}

test -s "$todo" || echo noop >> "$todo"
test -n "$autosquash" && rearrange_squash "$todo"
test -n "$cmd" && add_exec_commands "$todo"

cat >> "$todo" << EOF

# Rebase $shortrevisions onto $shortonto
EOF
append_todo_help
cat >> "$todo" << EOF
#
# However, if you remove everything, the rebase will be aborted.
#
EOF

if test -z "$keep_empty"
then
	echo "# Note that empty commits are commented out" >>"$todo"
fi


has_action "$todo" ||
	die_abort "Nothing to do"

cp "$todo" "$todo".backup
git_sequence_editor "$todo" ||
	die_abort "Could not execute editor"

has_action "$todo" ||
	die_abort "Nothing to do"

test -n "$force_rebase" || skip_unnecessary_picks

output git checkout $onto || die_abort "could not detach HEAD"
git update-ref ORIG_HEAD $orig_head
do_rest
