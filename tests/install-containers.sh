#!/usr/bin/env bash
# Runs tests/install-test.sh in fresh containers (docker or podman) for each distro, as root
# and as a user with sudo. Installs the working tree (uncommitted changes included).
# usage: tests/install-containers.sh [image...]    default: ubuntu, debian, fedora, arch
set -u
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/.." && pwd)
engine=$(command -v docker || command -v podman) || { echo "needs docker or podman"; exit 1; }
images=("$@")
(( ${#images[@]} )) || images=(ubuntu:24.04 debian:12 fedora:41 archlinux:latest)
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT

# The installer clones tmux-restore with git, which the container doesn't have until the
# installer installs it, so hand it a bundle of the working tree named "tmux-restore".
cp -a "$repo" "$D/work"
git -C "$D/work" add -A
git -C "$D/work" -c user.name=test -c user.email=test@example.com commit -qm "working tree" --allow-empty
git -C "$D/work" checkout -q -B main # CI checks out a detached HEAD
mkdir "$D/src"
git -C "$D/work" bundle create -q "$D/src/tmux-restore" HEAD main

# Packages the base images lack that a real machine always has, so the run below only tests the
# installer: sudo for the sudo user, and ps/flock where the image is minimal. Arch upgrades
# everything first (-Syu): with -Sy alone it's a partial upgrade, which Arch doesn't support and
# which fails whenever the image is older than the package repositories.
setup='
if command -v apt-get >/dev/null; then apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq sudo procps ca-certificates >/dev/null
elif command -v dnf >/dev/null; then dnf install -y -q sudo procps-ng util-linux >/dev/null
elif command -v pacman >/dev/null; then pacman -Syu --noconfirm --needed sudo procps-ng >/dev/null; fi
useradd -m tester && echo "tester ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/tester'
status=0
for image in "${images[@]}"; do
	for who in root tester; do
		if [[ $who == root ]]; then runs="fresh existing dirty running"; else runs="fresh"; fi
		echo "=== $image as $who: $runs"
		"$engine" run --rm -v "$repo:/repo:ro" -v "$D/src:/src:ro" "$image" bash -c "
			$setup
			cp -r /repo /home/tester/repo && chown -R tester /home/tester/repo
			for s in $runs; do
				if [ $who = root ]; then
					TMUX_RESTORE_SANDBOX=1 TMUX_RESTORE_SOURCE=/src/tmux-restore bash /home/tester/repo/tests/install-test.sh \$s || exit 1
				else
					su tester -c \"TMUX_RESTORE_SANDBOX=1 TMUX_RESTORE_SOURCE=/src/tmux-restore bash /home/tester/repo/tests/install-test.sh \$s\" || exit 1
				fi
			done" 2>&1 | sed 's/^/  /'
		[[ ${PIPESTATUS[0]} == 0 ]] || status=1
	done
done
exit $status
