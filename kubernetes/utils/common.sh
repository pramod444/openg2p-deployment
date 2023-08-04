#!/usr/bin/env bash

function generate_random_secret(){
  LC_ALL=C tr -dc '[:alnum:]' < /dev/urandom | head -c32
}
