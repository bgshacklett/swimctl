#!/bin/sh

# trick setup-alpine to pretend existing SSH connection
# and therefore keep (do not reset) network interfaces while running in background
# requires alpine-conf 3.15.1 and later, available from Alpine 3.17
# SSH_CONNECTION="FAKE" setup-alpine -ef /tmp/ANSWERFILE
