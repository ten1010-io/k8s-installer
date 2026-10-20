#!/bin/sh

# keepalived calls this with four words: the kind of thing that changed, its
# name, the state it is now in and the priority it carries. The third is the
# only one anybody downstream reads.
#
# One word to one file, and nothing else on purpose. What the state means on a
# cloud is a call to its api, which wants the credentials of the instance and a
# signer, and this container has neither and should not be given them. The host
# has both, in the python of this installer, and a path unit there watches this
# file. Written beside and moved into place so that a reader never sees
# half a word
state_dir=/etc/keepalived/state

printf '%s\n' "$3" > "$state_dir/vrrp.tmp" && mv -f "$state_dir/vrrp.tmp" "$state_dir/vrrp"
