#!/bin/sh
#
# Copyright (c) 2020 Jiang Xin
#

test_description='Test proc-receive hook'

. ./test-lib.sh

# Create commits in <repo> and assign each commit's oid to shell variables
# given in the arguments (A, B, and C). E.g.:
#
#     create_commits_in <repo> A B C
#
# NOTE: Avoid calling this function from a subshell since variable
# assignments will disappear when subshell exits.
create_commits_in () {
	repo="$1" &&
	if ! parent=$(git -C "$repo" rev-parse HEAD^{} 2>/dev/null)
	then
		parent=
	fi &&
	T=$(git -C "$repo" write-tree) &&
	shift &&
	while test $# -gt 0
	do
		name=$1 &&
		test_tick &&
		if test -z "$parent"
		then
			oid=$(echo $name | git -C "$repo" commit-tree $T)
		else
			oid=$(echo $name | git -C "$repo" commit-tree -p $parent $T)
		fi &&
		eval $name=$oid &&
		parent=$oid &&
		shift ||
		return 1
	done &&
	git -C "$repo" update-ref refs/heads/master $oid
}

format_git_output () {
	sed \
		-e "s/  *\$//g" \
		-e "s/$A/<COMMIT-A>/g" \
		-e "s/$B/<COMMIT-B>/g" \
		-e "s/$TAG/<COMMIT-T>/g" \
		-e "s/$ZERO_OID/<ZERO-OID>/g" \
		-e "s/'/\"/g"
}

# Asynchronous sideband may generate inconsistent output messages,
# sort before comparison.
test_sorted_cmp () {
	if ! $GIT_TEST_CMP "$@"
	then
		cmd=$GIT_TEST_CMP
		for f in "$@"
		do
			sort "$f" >"$f.sorted"
			cmd="$cmd \"$f.sorted\""
		done
		if ! eval $cmd
		then
			$GIT_TEST_CMP "$@"
		fi
	fi
}

test_expect_success "setup" '
	git init --bare upstream &&
	git init workbench &&
	create_commits_in workbench A B &&
	(
		cd workbench &&
		git remote add origin ../upstream &&
		git config core.abbrev 7 &&
		git update-ref refs/heads/master $A &&
		git tag -m "v1.0.0" v1.0.0 $A &&
		git push origin \
			$B:refs/heads/master \
			$A:refs/heads/next
	) &&
	TAG=$(cd workbench; git rev-parse v1.0.0) &&

	# setup pre-receive hook
	cat >upstream/hooks/pre-receive <<-EOF &&
	#!/bin/sh

	printf >&2 "# pre-receive hook\n"

	while read old new ref
	do
		printf >&2 "pre-receive< \$old \$new \$ref\n"
	done
	EOF

	# setup post-receive hook
	cat >upstream/hooks/post-receive <<-EOF &&
	#!/bin/sh

	printf >&2 "# post-receive hook\n"

	while read old new ref
	do
		printf >&2 "post-receive< \$old \$new \$ref\n"
	done
	EOF

	chmod a+x \
		upstream/hooks/pre-receive \
		upstream/hooks/post-receive
'

test_expect_success "normal git-push command" '
	(
		cd workbench &&
		git push -f origin \
			refs/tags/v1.0.0 \
			:refs/heads/next \
			HEAD:refs/heads/master \
			HEAD:refs/review/master/topic \
			HEAD:refs/heads/a/b/c
	) >out 2>&1 &&
	format_git_output <out >actual &&
	cat >expect <<-EOF &&
	remote: # pre-receive hook
	remote: pre-receive< <COMMIT-B> <COMMIT-A> refs/heads/master
	remote: pre-receive< <COMMIT-A> <ZERO-OID> refs/heads/next
	remote: pre-receive< <ZERO-OID> <COMMIT-T> refs/tags/v1.0.0
	remote: pre-receive< <ZERO-OID> <COMMIT-A> refs/review/master/topic
	remote: pre-receive< <ZERO-OID> <COMMIT-A> refs/heads/a/b/c
	remote: # post-receive hook
	remote: post-receive< <COMMIT-B> <COMMIT-A> refs/heads/master
	remote: post-receive< <COMMIT-A> <ZERO-OID> refs/heads/next
	remote: post-receive< <ZERO-OID> <COMMIT-T> refs/tags/v1.0.0
	remote: post-receive< <ZERO-OID> <COMMIT-A> refs/review/master/topic
	remote: post-receive< <ZERO-OID> <COMMIT-A> refs/heads/a/b/c
	To ../upstream
	 + ce858e6...1029397 HEAD -> master (forced update)
	 - [deleted]         next
	 * [new tag]         v1.0.0 -> v1.0.0
	 * [new reference]   HEAD -> refs/review/master/topic
	 * [new branch]      HEAD -> a/b/c
	EOF
	test_cmp expect actual &&
	(
		cd upstream &&
		git show-ref
	) >out &&
	format_git_output <out >actual &&
	cat >expect <<-EOF &&
	<COMMIT-A> refs/heads/a/b/c
	<COMMIT-A> refs/heads/master
	<COMMIT-A> refs/review/master/topic
	<COMMIT-T> refs/tags/v1.0.0
	EOF
	test_cmp expect actual
'

test_expect_success "cleanup" '
	(
		cd upstream &&
		git update-ref -d refs/review/master/topic &&
		git update-ref -d refs/tags/v1.0.0 &&
		git update-ref -d refs/heads/a/b/c
	)
'

test_expect_success "add two receive.procReceiveRefs settings" '
	(
		cd upstream &&
		git config --add receive.procReceiveRefs refs/for/ &&
		git config --add receive.procReceiveRefs refs/review/
	)
'

test_expect_success "no proc-receive hook, fail to push special ref" '
	(
		cd workbench &&
		test_must_fail git push origin \
			HEAD:next \
			HEAD:refs/for/master/topic
	) >out 2>&1 &&
	format_git_output <out >actual &&
	cat >expect <<-EOF &&
	remote: # pre-receive hook
	remote: pre-receive< <ZERO-OID> <COMMIT-A> refs/heads/next
	remote: pre-receive< <ZERO-OID> <COMMIT-A> refs/for/master/topic
	remote: error: cannot to find hook "proc-receive"
	remote: # post-receive hook
	remote: post-receive< <ZERO-OID> <COMMIT-A> refs/heads/next
	To ../upstream
	 * [new branch]      HEAD -> next
	 ! [remote rejected] HEAD -> refs/for/master/topic (fail to run proc-receive hook)
	error: failed to push some refs to "../upstream"
	EOF
	test_cmp expect actual &&
	(
		cd upstream &&
		git show-ref
	) >out &&
	format_git_output <out >actual &&
	cat >expect <<-EOF &&
	<COMMIT-A> refs/heads/master
	<COMMIT-A> refs/heads/next
	EOF
	test_cmp expect actual
'

test_expect_success "cleanup" '
	(
		cd upstream &&
		git update-ref -d refs/heads/next
	)
'

# TODO: report for the failure of master branch is unnecessary.
test_expect_success "no proc-receive hook, fail all for atomic push" '
	(
		cd workbench &&
		test_must_fail git push --atomic origin \
			HEAD:next \
			HEAD:refs/for/master/topic
	) >out 2>&1 &&
	format_git_output <out >actual &&
	cat >expect <<-EOF &&
	remote: # pre-receive hook
	remote: pre-receive< <ZERO-OID> <COMMIT-A> refs/heads/next
	remote: pre-receive< <ZERO-OID> <COMMIT-A> refs/for/master/topic
	remote: error: cannot to find hook "proc-receive"
	To ../upstream
	 ! [rejected]        master (atomic push failed)
	 ! [remote rejected] HEAD -> next (fail to run proc-receive hook)
	 ! [remote rejected] HEAD -> refs/for/master/topic (fail to run proc-receive hook)
	error: failed to push some refs to "../upstream"
	EOF
	test_cmp expect actual &&
	(
		cd upstream &&
		git show-ref
	) >out &&
	format_git_output <out >actual &&
	cat >expect <<-EOF &&
	<COMMIT-A> refs/heads/master
	EOF
	test_cmp expect actual
'

test_expect_success "setup proc-receive hook (bad version)" '
	cat >upstream/hooks/proc-receive <<-EOF &&
	#!/bin/sh

	printf >&2 "# proc-receive hook\n"

	test-tool proc-receive -v --version 2
	EOF
	chmod a+x upstream/hooks/proc-receive
'

test_expect_success "proc-receive bad protocol: unknown version" '
	(
		cd workbench &&
		test_must_fail git push origin \
			HEAD:refs/for/master/topic
	) >out 2>&1 &&
	format_git_output <out | grep "protocol error" >actual &&
	cat >expect <<-EOF &&
	fatal: protocol error: unknown proc-receive version "2"
	EOF
	test_cmp expect actual &&
	(
		cd upstream &&
		git show-ref
	) >out &&
	format_git_output <out >actual &&
	cat >expect <<-EOF &&
	<COMMIT-A> refs/heads/master
	EOF
	test_cmp expect actual
'

test_expect_success "setup proc-receive hook (no report)" '
	cat >upstream/hooks/proc-receive <<-EOF
	#!/bin/sh

	printf >&2 "# proc-receive hook\n"

	test-tool proc-receive -v
	EOF
'

test_expect_success "proc-receive bad protocol: no report" '
	(
		cd workbench &&
		test_must_fail git push origin \
			HEAD:refs/for/master/topic
	) >out 2>&1 &&
	format_git_output <out >actual &&
	cat >expect <<-EOF &&
	remote: # pre-receive hook
	remote: pre-receive< <ZERO-OID> <COMMIT-A> refs/for/master/topic
	remote: # proc-receive hook
	remote: proc-receive< <ZERO-OID> <COMMIT-A> refs/for/master/topic
	To ../upstream
	 ! [remote failure]  HEAD -> refs/for/master/topic (remote failed to report status)
	error: failed to push some refs to "../upstream"
	EOF
	test_cmp expect actual &&
	(
		cd upstream &&
		git show-ref
	) >out &&
	format_git_output <out >actual &&
	cat >expect <<-EOF &&
	<COMMIT-A> refs/heads/master
	EOF
	test_cmp expect actual
'

test_expect_success "setup proc-receive hook (bad oid)" '
	cat >upstream/hooks/proc-receive <<-EOF
	#!/bin/sh

	printf >&2 "# proc-receive hook\n"

	test-tool proc-receive -v \
		-r "bad-id new-id ref ok"
	EOF
'

test_expect_success "proc-receive bad protocol: bad oid" '
	(
		cd workbench &&
		test_must_fail git push origin \
			HEAD:refs/for/master/topic
	) >out 2>&1 &&
	format_git_output <out | grep "protocol error" >actual &&
	cat >expect <<-EOF &&
	fatal: protocol error: proc-receive expected "old new ref status [msg]", got "bad-id new-id ref ok"
	EOF
	test_cmp expect actual &&
	(
		cd upstream &&
		git show-ref
	) >out &&
	format_git_output <out >actual &&
	cat >expect <<-EOF &&
	<COMMIT-A> refs/heads/master
	EOF
	test_cmp expect actual
'

test_expect_success "setup proc-receive hook (no status)" '
	cat >upstream/hooks/proc-receive <<-EOF
	#!/bin/sh

	printf >&2 "# proc-receive hook\n"

	test-tool proc-receive -v \
		-r "$ZERO_OID $A refs/for/master/topic"
	EOF
'

test_expect_success "proc-receive bad protocol: no status" '
	(
		cd workbench &&
		test_must_fail git push origin \
			HEAD:refs/for/master/topic
	) >out 2>&1 &&
	format_git_output <out | grep "protocol error" >actual &&
	cat >expect <<-EOF &&
	fatal: protocol error: proc-receive expected "old new ref status [msg]", got "<ZERO-OID> <COMMIT-A> refs/for/master/topic"
	EOF
	test_cmp expect actual &&
	(
		cd upstream &&
		git show-ref
	) >out &&
	format_git_output <out >actual &&
	cat >expect <<-EOF &&
	<COMMIT-A> refs/heads/master
	EOF
	test_cmp expect actual
'

test_expect_success "setup proc-receive hook (unknown status)" '
	cat >upstream/hooks/proc-receive <<-EOF
	#!/bin/sh

	printf >&2 "# proc-receive hook\n"

	test-tool proc-receive -v \
		-r "$ZERO_OID $A refs/for/master/topic xx msg"
	EOF
'

test_expect_success "proc-receive bad protocol: unknown status" '
	(
		cd workbench &&
		test_must_fail git push origin \
			HEAD:refs/for/master/topic
	) >out 2>&1 &&
	format_git_output <out | grep "protocol error" >actual &&
	cat >expect <<-EOF &&
	fatal: protocol error: proc-receive has bad status "xx" for "<ZERO-OID> <COMMIT-A> refs/for/master/topic"
	EOF
	test_cmp expect actual &&
	(
		cd upstream &&
		git show-ref
	) >out &&
	format_git_output <out >actual &&
	cat >expect <<-EOF &&
	<COMMIT-A> refs/heads/master
	EOF
	test_cmp expect actual
'

test_expect_success "setup proc-receive hook (bad status)" '
	cat >upstream/hooks/proc-receive <<-EOF
	#!/bin/sh

	printf >&2 "# proc-receive hook\n"

	test-tool proc-receive -v \
		-r "$ZERO_OID $A refs/for/master/topic bad status"
	EOF
'

test_expect_success "proc-receive bad protocol: bad status" '
	(
		cd workbench &&
		test_must_fail git push origin \
			HEAD:refs/for/master/topic
	) >out 2>&1 &&
	format_git_output <out | grep "protocol error" >actual &&
	cat >expect <<-EOF &&
	fatal: protocol error: proc-receive has bad status "bad status" for "<ZERO-OID> <COMMIT-A> refs/for/master/topic"
	EOF
	test_cmp expect actual &&
	(
		cd upstream &&
		git show-ref
	) >out &&
	format_git_output <out >actual &&
	cat >expect <<-EOF &&
	<COMMIT-A> refs/heads/master
	EOF
	test_cmp expect actual
'

test_expect_success "setup proc-receive hook (ng)" '
	cat >upstream/hooks/proc-receive <<-EOF
	#!/bin/sh

	printf >&2 "# proc-receive hook\n"

	test-tool proc-receive -v \
		-r "$ZERO_OID $A refs/for/master/topic ng"
	EOF
'

test_expect_success "proc-receive: fail to update (no message)" '
	(
		cd workbench &&
		test_must_fail git push origin \
			HEAD:refs/for/master/topic
	) >out 2>&1 &&
	format_git_output <out >actual &&
	cat >expect <<-EOF &&
	remote: # pre-receive hook
	remote: pre-receive< <ZERO-OID> <COMMIT-A> refs/for/master/topic
	remote: # proc-receive hook
	remote: proc-receive< <ZERO-OID> <COMMIT-A> refs/for/master/topic
	remote: proc-receive> <ZERO-OID> <COMMIT-A> refs/for/master/topic ng
	To ../upstream
	 ! [remote rejected] HEAD -> refs/for/master/topic (failed)
	error: failed to push some refs to "../upstream"
	EOF
	test_cmp expect actual &&
	(
		cd upstream &&
		git show-ref
	) >out &&
	format_git_output <out >actual &&
	cat >expect <<-EOF &&
	<COMMIT-A> refs/heads/master
	EOF
	test_cmp expect actual
'

test_expect_success "setup proc-receive hook (ng message)" '
	cat >upstream/hooks/proc-receive <<-EOF
	#!/bin/sh

	printf >&2 "# proc-receive hook\n"

	test-tool proc-receive -v \
		-r "$ZERO_OID $A refs/for/master/topic ng error msg"
	EOF
'

test_expect_success "proc-receive: fail to update (has message)" '
	(
		cd workbench &&
		test_must_fail git push origin \
			HEAD:refs/for/master/topic
	) >out 2>&1 &&
	format_git_output <out >actual &&
	cat >expect <<-EOF &&
	remote: # pre-receive hook
	remote: pre-receive< <ZERO-OID> <COMMIT-A> refs/for/master/topic
	remote: # proc-receive hook
	remote: proc-receive< <ZERO-OID> <COMMIT-A> refs/for/master/topic
	remote: proc-receive> <ZERO-OID> <COMMIT-A> refs/for/master/topic ng error msg
	To ../upstream
	 ! [remote rejected] HEAD -> refs/for/master/topic (error msg)
	error: failed to push some refs to "../upstream"
	EOF
	test_cmp expect actual &&
	(
		cd upstream &&
		git show-ref
	) >out &&
	format_git_output <out >actual &&
	cat >expect <<-EOF &&
	<COMMIT-A> refs/heads/master
	EOF
	test_cmp expect actual
'

test_expect_success "setup proc-receive hook (ok)" '
	cat >upstream/hooks/proc-receive <<-EOF
	#!/bin/sh

	printf >&2 "# proc-receive hook\n"

	test-tool proc-receive -v \
		-r "$ZERO_OID $A refs/for/master/topic ok"
	EOF
'

test_expect_success "proc-receive: ok" '
	(
		cd workbench &&
		git push origin \
			HEAD:refs/for/master/topic
	) >out 2>&1 &&
	format_git_output <out >actual &&
	cat >expect <<-EOF &&
	remote: # pre-receive hook
	remote: pre-receive< <ZERO-OID> <COMMIT-A> refs/for/master/topic
	remote: # proc-receive hook
	remote: proc-receive< <ZERO-OID> <COMMIT-A> refs/for/master/topic
	remote: proc-receive> <ZERO-OID> <COMMIT-A> refs/for/master/topic ok
	remote: # post-receive hook
	remote: post-receive< <ZERO-OID> <COMMIT-A> refs/for/master/topic
	To ../upstream
	 * [new reference]   HEAD -> refs/for/master/topic
	EOF
	test_cmp expect actual &&
	(
		cd upstream &&
		git show-ref
	) >out &&
	format_git_output <out >actual &&
	cat >expect <<-EOF &&
	<COMMIT-A> refs/heads/master
	EOF
	test_cmp expect actual
'

test_expect_success "proc-receive: report unknown ref" '
	(
		cd workbench &&
		test_must_fail git push origin \
			HEAD:refs/for/a/b/c/my/topic
	) >out 2>&1 &&
	format_git_output <out >actual &&
	cat >expect <<-EOF &&
	remote: # pre-receive hook
	remote: pre-receive< <ZERO-OID> <COMMIT-A> refs/for/a/b/c/my/topic
	remote: # proc-receive hook
	remote: proc-receive< <ZERO-OID> <COMMIT-A> refs/for/a/b/c/my/topic
	remote: proc-receive> <ZERO-OID> <COMMIT-A> refs/for/master/topic ok
	warning: remote reported status on unknown ref: refs/for/master/topic
	remote: # post-receive hook
	remote: post-receive< <ZERO-OID> <COMMIT-A> refs/for/master/topic
	To ../upstream
	 ! [remote failure]  HEAD -> refs/for/a/b/c/my/topic (remote failed to report status)
	error: failed to push some refs to "../upstream"
	EOF
	test_cmp expect actual &&
	(
		cd upstream &&
		git show-ref
	) >out &&
	format_git_output <out >actual &&
	cat >expect <<-EOF &&
	<COMMIT-A> refs/heads/master
	EOF
	test_cmp expect actual
'

test_expect_success "not support push options" '
	(
		cd workbench &&
		test_must_fail git push \
			-o issue=123 \
			-o reviewer=user1 \
			origin \
			HEAD:refs/for/master/topic
	) >out 2>&1 &&
	format_git_output <out >actual &&
	cat >expect <<-EOF &&
	fatal: the receiving end does not support push options
	fatal: the remote end hung up unexpectedly
	EOF
	test_cmp expect actual &&
	(
		cd upstream &&
		git show-ref
	) >out &&
	format_git_output <out >actual &&
	cat >expect <<-EOF &&
	<COMMIT-A> refs/heads/master
	EOF
	test_cmp expect actual
'

test_expect_success "enable push options" '
	(
		cd upstream &&
		git config receive.advertisePushOptions true
	)
'

test_expect_success "push with options" '
	(
		cd workbench &&
		git push \
			-o issue=123 \
			-o reviewer=user1 \
			origin \
			HEAD:refs/heads/next \
			HEAD:refs/for/master/topic
	) >out 2>&1 &&
	format_git_output <out >actual &&
	cat >expect <<-EOF &&
	remote: # pre-receive hook
	remote: pre-receive< <ZERO-OID> <COMMIT-A> refs/heads/next
	remote: pre-receive< <ZERO-OID> <COMMIT-A> refs/for/master/topic
	remote: # proc-receive hook
	remote: proc-receive< <ZERO-OID> <COMMIT-A> refs/for/master/topic
	remote: proc-receive< issue=123
	remote: proc-receive< reviewer=user1
	remote: proc-receive> <ZERO-OID> <COMMIT-A> refs/for/master/topic ok
	remote: # post-receive hook
	remote: post-receive< <ZERO-OID> <COMMIT-A> refs/for/master/topic
	remote: post-receive< <ZERO-OID> <COMMIT-A> refs/heads/next
	To ../upstream
	 * [new branch]      HEAD -> next
	 * [new reference]   HEAD -> refs/for/master/topic
	EOF
	test_cmp expect actual &&
	(
		cd upstream &&
		git show-ref
	) >out &&
	format_git_output <out >actual &&
	cat >expect <<-EOF &&
	<COMMIT-A> refs/heads/master
	<COMMIT-A> refs/heads/next
	EOF
	test_cmp expect actual
'

test_expect_success "cleanup" '
	(
		cd upstream &&
		git update-ref -d refs/heads/next
	)
'

test_expect_success "setup proc-receive hook" '
	cat >upstream/hooks/proc-receive <<-EOF &&
	#!/bin/sh

	printf >&2 "# proc-receive hook\n"

	test-tool proc-receive -v \
		-r "$ZERO_OID $A refs/for/next/topic ok ref:refs/pull/123/head" \
		-r "$ZERO_OID $A refs/review/a/b/c/topic ok" \
		-r "$ZERO_OID $A refs/for/master/topic ok ref:refs/pull/124/head"
	EOF
	chmod a+x upstream/hooks/proc-receive
'

test_expect_success "report update of all special refs" '
	(
		cd workbench &&
		git push origin \
			HEAD:refs/for/next/topic \
			HEAD:refs/review/a/b/c/topic \
			HEAD:refs/for/master/topic
	) >out 2>&1 &&
	format_git_output <out >actual &&
	cat >expect <<-EOF &&
	remote: # pre-receive hook
	remote: pre-receive< <ZERO-OID> <COMMIT-A> refs/for/next/topic
	remote: pre-receive< <ZERO-OID> <COMMIT-A> refs/review/a/b/c/topic
	remote: pre-receive< <ZERO-OID> <COMMIT-A> refs/for/master/topic
	remote: # proc-receive hook
	remote: proc-receive< <ZERO-OID> <COMMIT-A> refs/for/next/topic
	remote: proc-receive< <ZERO-OID> <COMMIT-A> refs/review/a/b/c/topic
	remote: proc-receive< <ZERO-OID> <COMMIT-A> refs/for/master/topic
	remote: proc-receive> <ZERO-OID> <COMMIT-A> refs/for/next/topic ok ref:refs/pull/123/head
	remote: proc-receive> <ZERO-OID> <COMMIT-A> refs/review/a/b/c/topic ok
	remote: proc-receive> <ZERO-OID> <COMMIT-A> refs/for/master/topic ok ref:refs/pull/124/head
	remote: # post-receive hook
	remote: post-receive< <ZERO-OID> <COMMIT-A> refs/for/next/topic
	remote: post-receive< <ZERO-OID> <COMMIT-A> refs/review/a/b/c/topic
	remote: post-receive< <ZERO-OID> <COMMIT-A> refs/for/master/topic
	To ../upstream
	 * [new reference]   HEAD -> refs/pull/123/head
	 * [new reference]   HEAD -> refs/review/a/b/c/topic
	 * [new reference]   HEAD -> refs/pull/124/head
	EOF
	test_cmp expect actual &&
	(
		cd upstream &&
		git show-ref
	) >out &&
	format_git_output <out >actual &&
	cat >expect <<-EOF &&
	<COMMIT-A> refs/heads/master
	EOF
	test_cmp expect actual
'

test_expect_success "setup proc-receive hook" '
	cat >upstream/hooks/proc-receive <<-EOF &&
	#!/bin/sh

	printf >&2 "# proc-receive hook\n"

	test-tool proc-receive -v \
		-r "$ZERO_OID $A refs/for/next/topic ok" \
		-r "$ZERO_OID $A refs/for/master/topic ok"
	EOF
	chmod a+x upstream/hooks/proc-receive
'

test_expect_success "report mixed refs update (head first)" '
	(
		cd workbench &&
		git push origin \
			HEAD:refs/heads/zzz \
			HEAD:refs/for/next/topic \
			HEAD:refs/heads/yyy \
			HEAD:refs/for/master/topic
	) >out 2>&1 &&
	format_git_output <out >actual &&
	cat >expect <<-EOF &&
	remote: # pre-receive hook
	remote: pre-receive< <ZERO-OID> <COMMIT-A> refs/heads/zzz
	remote: pre-receive< <ZERO-OID> <COMMIT-A> refs/for/next/topic
	remote: pre-receive< <ZERO-OID> <COMMIT-A> refs/heads/yyy
	remote: pre-receive< <ZERO-OID> <COMMIT-A> refs/for/master/topic
	remote: # proc-receive hook
	remote: proc-receive< <ZERO-OID> <COMMIT-A> refs/for/next/topic
	remote: proc-receive< <ZERO-OID> <COMMIT-A> refs/for/master/topic
	remote: proc-receive> <ZERO-OID> <COMMIT-A> refs/for/next/topic ok
	remote: proc-receive> <ZERO-OID> <COMMIT-A> refs/for/master/topic ok
	remote: # post-receive hook
	remote: post-receive< <ZERO-OID> <COMMIT-A> refs/for/next/topic
	remote: post-receive< <ZERO-OID> <COMMIT-A> refs/for/master/topic
	remote: post-receive< <ZERO-OID> <COMMIT-A> refs/heads/zzz
	remote: post-receive< <ZERO-OID> <COMMIT-A> refs/heads/yyy
	To ../upstream
	 * [new branch]      HEAD -> zzz
	 * [new reference]   HEAD -> refs/for/next/topic
	 * [new branch]      HEAD -> yyy
	 * [new reference]   HEAD -> refs/for/master/topic
	EOF
	test_cmp expect actual &&
	(
		cd upstream &&
		git show-ref
	) >out &&
	format_git_output <out >actual &&
	cat >expect <<-EOF &&
	<COMMIT-A> refs/heads/master
	<COMMIT-A> refs/heads/yyy
	<COMMIT-A> refs/heads/zzz
	EOF
	test_cmp expect actual
'

test_expect_success "cleanup" '
	(
		cd upstream &&
		git update-ref -d refs/heads/yyy &&
		git update-ref -d refs/heads/zzz
	)
'

test_expect_success "setup proc-receive hook" '
	cat >upstream/hooks/proc-receive <<-EOF &&
	#!/bin/sh

	printf >&2 "# proc-receive hook\n"

	test-tool proc-receive -v \
		-r "$ZERO_OID $A refs/for/next/topic ok" \
		-r "$ZERO_OID $A refs/review/a/b/c/topic ok" \
		-r "$ZERO_OID $A refs/for/master/topic ok"
	EOF
	chmod a+x upstream/hooks/proc-receive
'

test_expect_success "report mixed refs update (special ref first)" '
	(
		cd workbench &&
		git push origin \
			HEAD:refs/for/next/topic \
			$B:refs/heads/zzz \
			HEAD:refs/review/a/b/c/topic \
			HEAD:refs/heads/yyy \
			HEAD:refs/for/master/topic
	) >out 2>&1 &&
	format_git_output <out >actual &&
	cat >expect <<-EOF &&
	remote: # pre-receive hook
	remote: pre-receive< <ZERO-OID> <COMMIT-A> refs/for/next/topic
	remote: pre-receive< <ZERO-OID> <COMMIT-B> refs/heads/zzz
	remote: pre-receive< <ZERO-OID> <COMMIT-A> refs/review/a/b/c/topic
	remote: pre-receive< <ZERO-OID> <COMMIT-A> refs/heads/yyy
	remote: pre-receive< <ZERO-OID> <COMMIT-A> refs/for/master/topic
	remote: # proc-receive hook
	remote: proc-receive< <ZERO-OID> <COMMIT-A> refs/for/next/topic
	remote: proc-receive< <ZERO-OID> <COMMIT-A> refs/review/a/b/c/topic
	remote: proc-receive< <ZERO-OID> <COMMIT-A> refs/for/master/topic
	remote: proc-receive> <ZERO-OID> <COMMIT-A> refs/for/next/topic ok
	remote: proc-receive> <ZERO-OID> <COMMIT-A> refs/review/a/b/c/topic ok
	remote: proc-receive> <ZERO-OID> <COMMIT-A> refs/for/master/topic ok
	remote: # post-receive hook
	remote: post-receive< <ZERO-OID> <COMMIT-A> refs/for/next/topic
	remote: post-receive< <ZERO-OID> <COMMIT-B> refs/heads/zzz
	remote: post-receive< <ZERO-OID> <COMMIT-A> refs/heads/yyy
	remote: post-receive< <ZERO-OID> <COMMIT-A> refs/review/a/b/c/topic
	remote: post-receive< <ZERO-OID> <COMMIT-A> refs/for/master/topic
	To ../upstream
	 * [new reference]   HEAD -> refs/for/next/topic
	 * [new branch]      <COMMIT-B> -> zzz
	 * [new reference]   HEAD -> refs/review/a/b/c/topic
	 * [new branch]      HEAD -> yyy
	 * [new reference]   HEAD -> refs/for/master/topic
	EOF
	test_cmp expect actual &&
	(
		cd upstream &&
		git show-ref
	) >out &&
	format_git_output <out >actual &&
	cat >expect <<-EOF &&
	<COMMIT-A> refs/heads/master
	<COMMIT-A> refs/heads/yyy
	<COMMIT-B> refs/heads/zzz
	EOF
	test_cmp expect actual
'

test_expect_success "config receive.procReceiveRefs for all ref/" '
	(
		cd upstream &&
		git config --add receive.procReceiveRefs refs/
	)
'

test_expect_success "setup proc-receive hook" '
	cat >upstream/hooks/proc-receive <<-EOF &&
	#!/bin/sh

	printf >&2 "# proc-receive hook\n"

	test-tool proc-receive -v \
		-r "$A $ZERO_OID refs/heads/yyy ft" \
		-r "$B $A refs/heads/zzz ft" \
		-r "$A $B refs/for/master/topic ok ref:refs/pull/123/head" \
		-r "$A $B refs/heads/master ft" \
		-r "$B $A refs/for/next/topic ok ref:refs/pull/124/head"
	EOF
	chmod a+x upstream/hooks/proc-receive
'

test_expect_success "report test: fallthrough" '
	(
		cd workbench &&
		git push -f origin \
			:refs/heads/yyy \
			$A:refs/heads/zzz \
			HEAD:refs/for/master/topic \
			HEAD:refs/for/next/topic \
			$B:refs/heads/master
	) >out 2>&1 &&
	format_git_output <out >actual &&
	cat >expect <<-EOF &&
	remote: # pre-receive hook
	remote: pre-receive< <COMMIT-A> <COMMIT-B> refs/heads/master
	remote: pre-receive< <COMMIT-A> <ZERO-OID> refs/heads/yyy
	remote: pre-receive< <COMMIT-B> <COMMIT-A> refs/heads/zzz
	remote: pre-receive< <ZERO-OID> <COMMIT-A> refs/for/master/topic
	remote: pre-receive< <ZERO-OID> <COMMIT-A> refs/for/next/topic
	remote: # proc-receive hook
	remote: proc-receive< <COMMIT-A> <COMMIT-B> refs/heads/master
	remote: proc-receive< <COMMIT-A> <ZERO-OID> refs/heads/yyy
	remote: proc-receive< <COMMIT-B> <COMMIT-A> refs/heads/zzz
	remote: proc-receive< <ZERO-OID> <COMMIT-A> refs/for/master/topic
	remote: proc-receive< <ZERO-OID> <COMMIT-A> refs/for/next/topic
	remote: proc-receive> <COMMIT-A> <ZERO-OID> refs/heads/yyy ft
	remote: proc-receive> <COMMIT-B> <COMMIT-A> refs/heads/zzz ft
	remote: proc-receive> <COMMIT-A> <COMMIT-B> refs/for/master/topic ok ref:refs/pull/123/head
	remote: proc-receive> <COMMIT-A> <COMMIT-B> refs/heads/master ft
	remote: proc-receive> <COMMIT-B> <COMMIT-A> refs/for/next/topic ok ref:refs/pull/124/head
	remote: # post-receive hook
	remote: post-receive< <COMMIT-A> <ZERO-OID> refs/heads/yyy
	remote: post-receive< <COMMIT-B> <COMMIT-A> refs/heads/zzz
	remote: post-receive< <COMMIT-A> <COMMIT-B> refs/for/master/topic
	remote: post-receive< <COMMIT-A> <COMMIT-B> refs/heads/master
	remote: post-receive< <COMMIT-B> <COMMIT-A> refs/for/next/topic
	To ../upstream
	   1029397..ce858e6  <COMMIT-B> -> master
	 - [deleted]         yyy
	 + ce858e6...1029397 <COMMIT-A> -> zzz (forced update)
	 * [new reference]   HEAD -> refs/pull/123/head
	 * [new reference]   HEAD -> refs/pull/124/head
	EOF
	test_cmp expect actual &&
	(
		cd upstream &&
		git show-ref
	) >out &&
	format_git_output <out >actual &&
	cat >expect <<-EOF &&
	<COMMIT-B> refs/heads/master
	<COMMIT-A> refs/heads/zzz
	EOF
	test_cmp expect actual
'

test_done
