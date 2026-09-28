# shellcheck shell=bash
#
# Sourced by the scripts of this directory, after the cli template of each of
# them. The directive above names the shell this is read as, which a file with
# no shebang otherwise leaves unknown: a file that is sourced is not run, so it
# carries none.
#
# Only the two paths live here, and they live here because they have to agree
# between the setup and the reset. reset-kernel-config.sh decides whether any of
# this ever ran on a node by looking for these exact files, so a path that
# drifted between the two is a reset that quietly does nothing and a node that
# goes on loading modules for a cluster it left.
#
# The cli template at the top of each script is left duplicated, the way it is in
# every other script of this repository. Only what is particular to kernel-config
# is shared

# Both carry the name of the installer, so a file here is never confused with one
# the site wrote and the reset knows what is its to remove. Each file is also the
# record of what this put there: a list that shrank is applied by writing the file
# again, and what is no longer in it is what is no longer asked for.
#
# 99- does not put the sysctl file last. /etc/sysctl.d is read in the order the
# file names sort in, and "9" sorts before the "k" of the k8s.conf this installer
# writes for kubernetes, so k8s.conf is read after this file and wins a key they
# both set. Nothing depends on that today - validate-hostvars.py refuses a key
# k8s.conf already owns - and the name is left as it is because the reset of a
# node that was built by an earlier release looks for this exact one
MODULES_LOAD_PATH=/etc/modules-load.d/ki-kernel-modules.conf
SYSCTL_PATH=/etc/sysctl.d/99-ki-sysctl.conf
