#!/bin/bash

# Copy secrets from other namespaces
# DST_NS: Destination namespace

COPY_UTIL=../utils/copy_cm_func.sh
DST_NS=spar
$COPY_UTIL secret postgres-postgresql postgres $DST_NS 

