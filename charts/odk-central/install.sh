#!/usr/bin/env bash

NS=odk

kubectl create ns $NS

helm -n $NS install odk-central . "$@"
