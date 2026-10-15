# VERY DANGEROUS !!!!!!!
# Can only be run on the master host
# First, determine the duplicate SM record: xe sm-list type=linstor
# Then, run this script: bash remove_dup_sm.sh e1ff75c1-0a46-16ef-0876-1a35603a83de

SOCK=/var/lib/xcp/xapi
rpc() { curl -s --unix-socket "$SOCK" -H 'Content-Type: text/xml' \
        --data-binary "$1" http://localhost/remote_db_access; }

uuid="$1"

ref=$(rpc "<value><array><data>
  <value><string>db_get_by_uuid</string></value>
  <value><string></string></value>
  <value><array><data>
    <value><string>SM</string></value>
    <value><string>$uuid</string></value>
  </data></array></value>
</data></array></value>" | \
grep -oE 'OpaqueRef:[0-9a-fA-F-]+' | head -1)

rpc "<value><array><data>
  <value><string>delete_row</string></value>
  <value><string></string></value>
  <value><array><data>
    <value><string>SM</string></value>
    <value><string>$ref</string></value>
  </data></array></value>
</data></array></value>"
