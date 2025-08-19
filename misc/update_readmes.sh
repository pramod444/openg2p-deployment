#!/bin/sh
# This script is useful while releasing of packages where version number
# in Odoo packages has to be updated enmasse.
# ./update_readmes.sh <repo name>

SED=gsed
V1=15.0.1.1.0
V2=15.0.1.2.0
B1=15.0-1.1.0
B2=15.0-develop

find . -name __manifest__.py -exec $SED -i "s/$V1/$V2/g" {} \;
find . -name test-requirements.txt -exec $SED -i "s/$B1/$B2/g" {} \;

for dir in $(ls -d */); do
  	gsed -i "s#$(grep development_status $dir/__manifest__.py)#    \"development_status\": \"Alpha\",#g" $dir/__manifest__.py;
    oca-gen-addon-readme --repo-name=$1 --branch=$B2 --addon-dir=$dir --org-name=OpenG2P;
 done

oca-gen-addons-table

# Update badge URLs
gsed -i s/$B1/$B2/g README.md
